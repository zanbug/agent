#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # re-exec under bash when started via sh
# zanbug-agent — server & database monitoring agent for Zanbug (https://zanbug.com)
#
# Plain bash + curl, nothing to compile, runs as a systemd service on the box the
# app (or the database) lives on. Three modules, each switched on in
# /etc/zanbug/agent.conf (the installer does it: --server / --mysql / --postgres):
#
#   server    every SAMPLE_S seconds: load, CPU, iowait, RAM, swap, disk, disk IO,
#             network from /proc. Calm samples are batched and pushed with the
#             heartbeat; the moment a threshold is crossed (load per CPU, CPU %,
#             RAM %, disk %, iowait %) the sample is pushed immediately together
#             with the top processes — "what was running when load hit 9".
#   mysql     tails MySQL/MariaDB's own slow query log (so a query typed in the
#             terminal, phpMyAdmin or another app is caught too, not only what the
#             SDK sees), attaches the DB user@host, and posts it to the same
#             Performance tab (source "mysql-log"). On a spike it also grabs
#             SHOW PROCESSLIST. Daily inventory: triggers, routines, events,
#             biggest tables, slow-log settings.
#   postgres  same for PostgreSQL: log_min_duration_statement lines from the
#             server log, pg_stat_activity on a spike, inventory from pg_trigger /
#             pg_proc / pg_stat_user_tables.
#   redis     (1.2.0) every heartbeat: INFO (memory, hit/miss, evictions, ops),
#             keyspace and new SLOWLOG entries; every REDIS_SCAN_S a sampled
#             SCAN groups keys into NORMALIZED patterns ("cache:user:{n}") with
#             count / no-TTL / memory estimates. Key names leave the box only
#             normalized ({email}, {ip}, {n}…), values never. Cleanup of one key
#             group requested in the panel runs only with REDIS_ALLOW_ACTIONS=1.
#
# All thresholds and intervals come back from the API in every response
# (project → Server tab), so the panel tunes a running agent without a redeploy.
#
# Commands:  run (daemon) · test · once · inventory · status · setup-mysql [sec]
#            setup-postgres [ms] · backfill [slow-log file] · redis [scan] · version
#            exec [--name NAME] -- command [args...]   (1.3.0) wrap a cron job / shell
#            script: it runs exactly as before (same stdout/stderr/exit code), and
#            when it ends one row goes to the Processes tab (source cron, runtime
#            shell: duration, CPU, peak memory, exit code, stderr tail on failure).
#            Zanbug unreachable / no key / unreadable conf → the job still runs.
set -u
AGENT_VERSION="2.0.0"
# legacy: bugban → zanbug (2026-10-07) — old env overrides still honoured
[ -n "${BUGBAN_AGENT_CONF:-}" ] && [ -z "${ZANBUG_AGENT_CONF:-}" ] && ZANBUG_AGENT_CONF="$BUGBAN_AGENT_CONF"
[ -n "${BUGBAN_AGENT_STATE:-}" ] && [ -z "${ZANBUG_AGENT_STATE:-}" ] && ZANBUG_AGENT_STATE="$BUGBAN_AGENT_STATE"
[ -n "${BUGBAN_AGENT_LOG:-}" ] && [ -z "${ZANBUG_AGENT_LOG:-}" ] && ZANBUG_AGENT_LOG="$BUGBAN_AGENT_LOG"
CONF="${ZANBUG_AGENT_CONF:-/etc/zanbug/agent.conf}"
# legacy: bugban → zanbug (2026-10-07) — an un-migrated install keeps its old conf readable
[ -r "$CONF" ] || [ ! -r /etc/bugban/agent.conf ] || [ -n "${ZANBUG_AGENT_CONF:-}" ] || CONF=/etc/bugban/agent.conf
STATE_DIR="${ZANBUG_AGENT_STATE:-/var/lib/zanbug-agent}"
# legacy: bugban → zanbug (2026-10-07) — keep the old state dir (mysql.last_epoch, offsets) until the installer moves it
[ -d "$STATE_DIR" ] || [ ! -d /var/lib/bugban-agent ] || [ -n "${ZANBUG_AGENT_STATE:-}" ] || STATE_DIR=/var/lib/bugban-agent
LOG_FILE="${ZANBUG_AGENT_LOG:-/var/log/zanbug-agent.log}"
UA="zanbug-agent/$AGENT_VERSION"

# ---------------------------------------------------------------- config ----
ZANBUG_API_KEY=""; ZANBUG_HOST="https://zanbug.com"
MONITOR_SERVER=1; MONITOR_MYSQL=0; MONITOR_PGSQL=0
MYSQL_CMD="mysql"; MYSQL_SLOW_LOG=""; MYSQL_BACKLOG_LINES=5000
PG_CMD=""; PG_LOG_DIR=""
MONITOR_REDIS=0; REDIS_CLI="redis-cli"; REDIS_PASSWORD=""; REDIS_ALLOW_ACTIONS=0; REDIS_SCAN_KEYS=20000
HOST_NAME=""; DISK_PATH="/"; DEBUG=0
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
# legacy: bugban → zanbug (2026-10-07) — conf/env written for the old agent name map onto the new keys
[ -n "${BUGBAN_API_KEY:-}" ] && [ -z "$ZANBUG_API_KEY" ] && ZANBUG_API_KEY="$BUGBAN_API_KEY"
[ -n "${BUGBAN_HOST:-}" ] && [ "$ZANBUG_HOST" = "https://zanbug.com" ] && ZANBUG_HOST="$BUGBAN_HOST"
[ -n "${BUGBAN_AGENT_KEY:-}" ] && [ -z "${ZANBUG_AGENT_KEY:-}" ] && ZANBUG_AGENT_KEY="$BUGBAN_AGENT_KEY"
[ -n "${BUGBAN_AGENT_HOST:-}" ] && [ -z "${ZANBUG_AGENT_HOST:-}" ] && ZANBUG_AGENT_HOST="$BUGBAN_AGENT_HOST"
[ -n "${ZANBUG_AGENT_KEY:-}" ] && ZANBUG_API_KEY="$ZANBUG_AGENT_KEY"
[ -n "${ZANBUG_AGENT_HOST:-}" ] && ZANBUG_HOST="$ZANBUG_AGENT_HOST"
ZANBUG_HOST="${ZANBUG_HOST%/}"
# legacy: bugban → zanbug (2026-10-07) — the old panel domain moved with the product
case "$ZANBUG_HOST" in https://bugban.online|http://bugban.online) ZANBUG_HOST="https://zanbug.com";; esac
# password via env, never on the command line (ps would show it); redis-cli ≥ 5.0.3 reads it
[ -n "$REDIS_PASSWORD" ] && export REDISCLI_AUTH="$REDIS_PASSWORD"
if [ -z "$HOST_NAME" ]; then
    HOST_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)"
    HOST_NAME="${HOST_NAME%%.*}"
fi
HOST_NAME="$(printf '%s' "$HOST_NAME" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-120)"
if [ -z "$PG_CMD" ]; then
    if [ "$(id -u)" = "0" ] && id postgres >/dev/null 2>&1; then
        # setpriv = no PAM session → no "sudo: session opened" line in auth.log for every query
        if command -v setpriv >/dev/null 2>&1; then PG_CMD="setpriv --reuid=postgres --regid=postgres --init-groups psql"; else PG_CMD="sudo -u postgres psql"; fi
    else PG_CMD="psql"; fi
fi

# runtime config (server-driven; these are the fallbacks until the first response)
SAMPLE_S=5; HEARTBEAT_S=60; TOP_N=15; SPIKE_COOLDOWN_S=60; INVENTORY_S=86400; REDIS_SCAN_S=900
TH_LOAD=1.0; TH_CPU=85; TH_MEM=90; TH_DISK=90; TH_IOWAIT=40

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2 2>/dev/null; }
dbg() { [ "$DEBUG" = "1" ] && log "debug: $*"; return 0; }
die() { log "error: $*"; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
have() { command -v "$1" >/dev/null 2>&1; }
# mawk block-buffers piped input unless told otherwise (gawk/busybox ignore the flag → empty)
[ -n "$HOST_NAME" ] || [ "${1:-}" != "exec" ] || HOST_NAME="unknown"   # never block a wrapped job
[ -n "$HOST_NAME" ] || die "cannot determine the hostname (no hostname/uname) — set HOST_NAME=... in $CONF"
# busybox tail has no --pid: fall back to the kill -0 loop only
TP="--pid=$$"; tail --pid=$$ -n0 /dev/null >/dev/null 2>&1 || TP=""
AWK_I=""; _awk_out="$(awk -W interactive 'BEGIN{}' </dev/null 2>&1)" && [ -z "$_awk_out" ] && AWK_I="-W interactive"; unset _awk_out

# ------------------------------------------------------------- json bits ----
# JSON string literal from a bash string (quotes, backslashes, newlines, tabs; other control chars dropped).
jstr() {
    local s; s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
# number or null
jnum() { case "${1:-}" in ''|null) printf 'null';; *) printf '%s' "$1";; esac; }
# Tab-separated rows on stdin → JSON array of objects. $1 = comma-separated keys,
# $2 = comma-separated list of keys that are numeric (others become strings).
# "NULL" (mysql -N) and empty cells → null.
tsv_json() {
    awk -v keys="$1" -v nums="${2:-}" -F'\t' '
    function esc(s,  n,P,i,r){ n=split(s,P,/\\/); r=P[1]; for(i=2;i<=n;i++) r=r "\\\\" P[i]; n=split(r,P,/"/); s=P[1]; for(i=2;i<=n;i++) s=s "\\\"" P[i]; gsub(/\r/,"",s); gsub(/[\001-\037]/," ",s); return s }
    BEGIN{ n=split(keys,K,","); m=split(nums,NN,","); for(i=1;i<=m;i++) isnum[NN[i]]=1; printf "[" ; first=1 }
    NF>0 { if(!first) printf ","; first=0; printf "{";
        for(i=1;i<=n;i++){ v=$i; if(i>1) printf ",";
            printf "\"%s\":", K[i];
            if(v=="" || v=="NULL" || v=="\\N") printf "null";
            else if(isnum[K[i]] && v ~ /^-?[0-9]+(\.[0-9]+)?$/) printf "%s", v;
            else printf "\"%s\"", esc(v) }
        printf "}" }
    END{ printf "]" }'
}
# value of a numeric key from the API's JSON response (flat regex — keys are unique)
cfg_num() { printf '%s' "$2" | sed -n "s/.*\"$1\":\([0-9][0-9.]*\).*/\1/p" | head -n1; }

# --------------------------------------------------------------- sampling ----
CPUS="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo || echo 1)"
MEM_TOTAL_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
OS_NAME="$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}") || uname -s)"
prev_cpu=""; prev_io=""; prev_net=""; prev_t=0

# One sample as a JSON object. Rates need a previous reading, so the very first
# sample after start has cpu/io/net = null (the server accepts nulls).
sample_json() {
    local kind="${1:-sample}" reason="${2:-}" t l1 l5 l15 procs cpu_line
    t=$(date +%s)
    read -r l1 l5 l15 procs _ < /proc/loadavg; procs="${procs#*/}"
    cpu_line="$(grep -m1 '^cpu ' /proc/stat)"
    local cpu_pct="" iowait_pct=""
    if [ -n "$prev_cpu" ]; then
        read -r cpu_pct iowait_pct <<<"$(awk -v a="$prev_cpu" -v b="$cpu_line" 'BEGIN{
            split(a,A," "); split(b,B," "); tot=0; for(i=2;i<=9;i++) tot+=B[i]-A[i];
            idle=(B[5]-A[5])+(B[6]-A[6]); iow=B[6]-A[6];
            if(tot<=0){print "null null"; exit} printf "%.1f %.1f", 100*(tot-idle)/tot, 100*iow/tot }')"
    fi
    prev_cpu="$cpu_line"
    local mem_used_mb mem_pct swap_pct
    read -r mem_used_mb mem_pct swap_pct <<<"$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
        END{ u=t-a; printf "%d %.1f %s", u/1024, (t>0?100*u/t:0), (st>0? sprintf("%.1f",100*(st-sf)/st) : "0") }' /proc/meminfo)"
    local disk_pct; disk_pct="$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
    # disk IO: whole-disk devices only (sd*, vd*, xvd*, nvme*n*, md*), sectors → KB
    local io_line; io_line="$(awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|md[0-9]+)$/ {r+=$6; w+=$10} END{printf "%d %d", r/2, w/2}' /proc/diskstats)"
    local net_line; net_line="$(awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END{printf "%d %d", rx/1024, tx/1024}' /proc/net/dev)"
    local rd="null" wr="null" rx="null" tx="null"
    if [ -n "$prev_io" ] && [ "$prev_t" -gt 0 ] && [ $((t-prev_t)) -gt 0 ]; then
        read -r rd wr <<<"$(awk -v a="$prev_io" -v b="$io_line" -v dt="$((t-prev_t))" 'BEGIN{split(a,A," ");split(b,B," "); printf "%d %d", (B[1]-A[1])/dt, (B[2]-A[2])/dt}')"
        read -r rx tx <<<"$(awk -v a="$prev_net" -v b="$net_line" -v dt="$((t-prev_t))" 'BEGIN{split(a,A," ");split(b,B," "); printf "%d %d", (B[1]-A[1])/dt, (B[2]-A[2])/dt}')"
        [ "$rd" -lt 0 ] && rd=0; [ "$wr" -lt 0 ] && wr=0; [ "$rx" -lt 0 ] && rx=0; [ "$tx" -lt 0 ] && tx=0
    fi
    prev_io="$io_line"; prev_net="$net_line"; prev_t=$t
    LAST_L1="$l1"; LAST_CPU="$cpu_pct"; LAST_MEM="$mem_pct"; LAST_DISK="${disk_pct:-}"; LAST_IOWAIT="$iowait_pct"
    printf '{"captured_at":"%s","kind":"%s","cpus":%s,"load1":%s,"load5":%s,"load15":%s,"cpu_pct":%s,"iowait_pct":%s,"mem_used_mb":%s,"mem_pct":%s,"swap_pct":%s,"disk_pct":%s,"disk_read_kbs":%s,"disk_write_kbs":%s,"net_rx_kbs":%s,"net_tx_kbs":%s,"procs_total":%s' \
        "$(now_iso)" "$kind" "$CPUS" "$l1" "$l5" "$l15" "$(jnum "$cpu_pct")" "$(jnum "$iowait_pct")" "$mem_used_mb" "$mem_pct" "$swap_pct" "$(jnum "$disk_pct")" "$rd" "$wr" "$rx" "$tx" "$procs"
    if [ "$kind" = "spike" ]; then
        printf ',"reason":%s,"processes":%s,"db_processes":%s' "$(jstr "$reason")" "$(top_processes_json)" "$(db_processes_json)"
    fi
    printf '}'
}

# Top processes by CPU as JSON (pid, ppid, user, cpu, mem, rss_mb, etime seconds, cmd).
top_processes_json() {
    ps -eo pid=,ppid=,user=,pcpu=,pmem=,rss=,etimes=,args= --sort=-pcpu 2>/dev/null | head -n "$TOP_N" | awk '
    function esc(s,  n,P,i,r){ n=split(s,P,/\\/); r=P[1]; for(i=2;i<=n;i++) r=r "\\\\" P[i]; n=split(r,P,/"/); s=P[1]; for(i=2;i<=n;i++) s=s "\\\"" P[i]; gsub(/\r/,"",s); gsub(/[\001-\037]/," ",s); return s }
    BEGIN{printf "["; f=1}
    NF>=8 { cmd=""; for(i=8;i<=NF;i++) cmd=cmd (i>8?" ":"") $i; cmd=substr(cmd,1,300);
        if(!f) printf ","; f=0;
        printf "{\"pid\":%s,\"ppid\":%s,\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"rss_mb\":%d,\"etime\":%s,\"cmd\":\"%s\"}", $1,$2,esc($3),$4,$5,$6/1024,$7,esc(cmd) }
    END{printf "]"}'
}

# Live DB activity (only when a DB module is on) — the query that was running at the spike.
db_processes_json() {
    # Both engines are collected when both modules are on: {"mysql":[...],"postgres":[...]}.
    # A single engine is sent as a plain list (older servers accept both shapes).
    local my="" pg=""
    if [ "$MONITOR_MYSQL" = "1" ]; then
        # legacy: bugban → zanbug (2026-10-07) — also hide statements tagged by a not-yet-upgraded agent
        my="$($MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ ID,USER,HOST,DB,COMMAND,TIME,STATE,LEFT(REPLACE(REPLACE(INFO,'\n',' '),'\t',' '),600) FROM information_schema.PROCESSLIST WHERE COMMAND NOT IN ('Sleep','Daemon','Binlog Dump') AND (INFO IS NULL OR (INFO NOT LIKE '%zanbug-agent%' AND INFO NOT LIKE '%bugban-agent%')) ORDER BY TIME DESC LIMIT 50" 2>/dev/null | tsv_json "id,user,host,db,command,time,state,info" "id,time")"
        [ -z "$my" ] && my="[]"
    fi
    if [ "$MONITOR_PGSQL" = "1" ]; then
        # legacy: bugban → zanbug (2026-10-07) — same for pg_stat_activity
        pg="$($PG_CMD -X -q -At -F $'\t' -c "SELECT /* zanbug-agent */ pid, usename, coalesce(client_addr::text,'local'), datname, state, coalesce(extract(epoch from now()-query_start)::int,0), left(regexp_replace(query, '\s+', ' ', 'g'),600) FROM pg_stat_activity WHERE state IS NOT NULL AND state <> 'idle' AND pid <> pg_backend_pid() AND query NOT LIKE '%zanbug-agent%' AND query NOT LIKE '%bugban-agent%' ORDER BY 6 DESC LIMIT 50" 2>/dev/null | tsv_json "id,user,host,db,state,time,info" "id,time")"
        [ -z "$pg" ] && pg="[]"
    fi
    if [ -n "$my" ] && [ -n "$pg" ]; then printf '{"mysql":%s,"postgres":%s}' "$my" "$pg"
    elif [ -n "$my" ]; then printf '%s' "$my"
    elif [ -n "$pg" ]; then printf '%s' "$pg"
    else printf 'null'
    fi
}

# Which threshold did this sample cross? Empty = calm.
spike_reason() {
    awk -v l1="${LAST_L1:-0}" -v cpus="$CPUS" -v thl="$TH_LOAD" -v cpu="${LAST_CPU:-}" -v thc="$TH_CPU" -v mem="${LAST_MEM:-0}" -v thm="$TH_MEM" \
        -v disk="${LAST_DISK:-0}" -v thd="$TH_DISK" -v iow="${LAST_IOWAIT:-}" -v thi="$TH_IOWAIT" 'BEGIN{
        lim=cpus*thl; if (l1+0 > lim) { printf "load %.2f > %.2f", l1, lim; exit }
        if (cpu != "" && cpu != "null" && cpu+0 > thc) { printf "cpu %.0f%% > %d%%", cpu, thc; exit }
        if (mem+0 > thm) { printf "ram %.0f%% > %d%%", mem, thm; exit }
        if (disk != "" && disk+0 > thd) { printf "disk %.0f%% > %d%%", disk, thd; exit }
        if (iow != "" && iow != "null" && iow+0 > thi) { printf "iowait %.0f%% > %d%%", iow, thi; exit } }'
}

# -------------------------------------------------------------- inventory ----
# What exists on this box — the context AI needs to explain a spike: cron lines,
# running services & timers, listening ports, runtimes; plus, per DB module,
# triggers / routines / events / biggest tables / slow-log settings.
inventory_server_json() {
    local cron services timers ports
    cron="$( { [ -r /etc/crontab ] && grep -vE '^\s*(#|$)' /etc/crontab | tr '\t' ' ' | sed 's/^/etc\t/';
               for f in /etc/cron.d/*; do [ -f "$f" ] && grep -vhE '^\s*(#|$)' "$f" | tr '\t' ' ' | sed "s|^|cron.d/$(basename "$f")\t|"; done;
               for d in /var/spool/cron/crontabs /var/spool/cron; do [ -d "$d" ] && for f in "$d"/*; do [ -f "$f" ] && grep -vhE '^\s*(#|$)' "$f" | tr '\t' ' ' | sed "s|^|$(basename "$f")\t|"; done; done; } 2>/dev/null | head -n 200 | tsv_json "user,line")"
    services="$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | head -n 200 | tsv_json "name")"
    timers="$(systemctl list-timers --all --no-legend --plain 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/){print $i; break}}' | head -n 50 | tsv_json "name")"
    ports="$(ss -tlnpH 2>/dev/null | awk '{p=""; if (match($0,/users:\(\("[^"]+"/)) {p=substr($0,RSTART+9,RLENGTH-10)} print $4 "\t" p}' | sort -u | head -n 100 | tsv_json "addr,proc")"
    local php node uptime kernel
    php="$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"; node="$(node -v 2>/dev/null || true)"
    uptime="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"; kernel="$(uname -r 2>/dev/null || true)"
    printf '{"os":%s,"kernel":%s,"uptime_s":%s,"cpus":%s,"mem_total_mb":%s,"php":%s,"node":%s,"cron":%s,"services":%s,"timers":%s,"ports":%s}' \
        "$(jstr "$OS_NAME")" "$(jstr "$kernel")" "$uptime" "$CPUS" "$MEM_TOTAL_MB" "$( [ -n "$php" ] && jstr "$php" || printf null)" "$( [ -n "$node" ] && jstr "$node" || printf null)" "$cron" "$services" "$timers" "$ports"
}
# Every statement is tagged /* zanbug-agent */ so the slow-log parsers can drop the agent's
# own queries. The mysql client discards comments unless --comments is given (default
# --skip-comments, verified on 8.0.40) — without it the tag never reaches the server and
# a blocked FLUSH SLOW LOGS or a slow inventory SELECT would be reported as a customer query.
mq() { $MYSQL_CMD --comments -N -B -e "/* zanbug-agent */ $1" 2>/dev/null; }
inventory_mysql_json() {
    local ver settings status triggers routines events tables dbs
    ver="$(mq "SELECT /* zanbug-agent */ VERSION()")" || true
    [ -z "$ver" ] && { printf '{"error":"mysql not reachable (MYSQL_CMD=%s)"}' "$(jstr "$MYSQL_CMD" | tr -d '"')"; return; }
    settings="$(mq "SELECT /* zanbug-agent */ @@slow_query_log, @@long_query_time, @@slow_query_log_file, @@log_output, @@max_connections, ROUND(@@innodb_buffer_pool_size/1048576), @@datadir" | tsv_json "slow_query_log,long_query_time,slow_query_log_file,log_output,max_connections,innodb_buffer_pool_mb,datadir" "slow_query_log,long_query_time,max_connections,innodb_buffer_pool_mb")"
    status="$(mq "SHOW /* zanbug-agent */ GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Uptime','Questions','Slow_queries','Aborted_connects','Max_used_connections')" | tsv_json "name,value" "value")"
    triggers="$(mq "SELECT /* zanbug-agent */ TRIGGER_SCHEMA, EVENT_OBJECT_TABLE, TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY 1,2,3 LIMIT 300" | tsv_json "schema,table,name,timing,event")"
    routines="$(mq "SELECT /* zanbug-agent */ ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, LAST_ALTERED FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY 1,2 LIMIT 300" | tsv_json "schema,name,type,altered_at")"
    events="$(mq "SELECT /* zanbug-agent */ EVENT_SCHEMA, EVENT_NAME, STATUS, CONCAT(COALESCE(INTERVAL_VALUE,''),' ',COALESCE(INTERVAL_FIELD,'')), LAST_EXECUTED, EVENT_DEFINITION FROM information_schema.EVENTS ORDER BY 1,2 LIMIT 100" | tsv_json "schema,name,status,every,last_run,definition")"
    tables="$(mq "SELECT /* zanbug-agent */ TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS, ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') AND TABLE_TYPE='BASE TABLE' ORDER BY 5 DESC LIMIT 40" | tsv_json "schema,table,engine,rows,size_mb" "rows,size_mb")"
    dbs="$(mq "SELECT /* zanbug-agent */ SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema')" | tsv_json "name")"
    printf '{"version":%s,"settings":%s,"status":%s,"databases":%s,"triggers":%s,"routines":%s,"events":%s,"tables":%s,"event_scheduler":%s}' \
        "$(jstr "$ver")" "${settings:-null}" "${status:-null}" "${dbs:-null}" "${triggers:-[]}" "${routines:-[]}" "${events:-[]}" "${tables:-[]}" "$(jstr "$(mq "SELECT @@event_scheduler")")"
}
pq() { $PG_CMD -X -q -At -F $'\t' ${2:+-d "$2"} -c "/* zanbug-agent */ $1" 2>/dev/null; }
inventory_pgsql_json() {
    local ver settings dbs triggers="" functions="" tables="" activity ext d
    ver="$(pq "SELECT /* zanbug-agent */ version()")" || true
    [ -z "$ver" ] && { printf '{"error":"postgres not reachable (PG_CMD=%s)"}' "$(jstr "$PG_CMD" | tr -d '"')"; return; }
    settings="$(pq "SELECT /* zanbug-agent */ name, setting FROM pg_settings WHERE name IN ('log_min_duration_statement','logging_collector','log_directory','log_filename','log_line_prefix','data_directory','max_connections','shared_buffers','work_mem','log_destination')" | tsv_json "name,value")"
    activity="$(pq "SELECT /* zanbug-agent */ coalesce(state,'(none)'), count(*) FROM pg_stat_activity GROUP BY 1" | tsv_json "state,count" "count")"
    ext="$(pq "SELECT /* zanbug-agent */ extname, extversion FROM pg_extension" | tsv_json "name,version")"
    dbs="$(pq "SELECT /* zanbug-agent */ datname, pg_database_size(datname)/1048576 FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 2 DESC LIMIT 20" )"
    local dbs_json; dbs_json="$(printf '%s\n' "$dbs" | tsv_json "name,size_mb" "size_mb")"
    local first=1; triggers="["; functions="["; tables="["
    while IFS=$'\t' read -r d _; do
        [ -z "$d" ] && continue
        local t f tb
        t="$(pq "SELECT /* zanbug-agent */ '$d', n.nspname, c.relname, t.tgname, CASE t.tgenabled WHEN 'D' THEN 'disabled' ELSE 'enabled' END, p.proname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid WHERE NOT t.tgisinternal ORDER BY 2,3,4 LIMIT 200" "$d")"
        f="$(pq "SELECT /* zanbug-agent */ '$d', n.nspname, p.proname, l.lanname, CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'f' THEN 'function' WHEN 'a' THEN 'aggregate' ELSE p.prokind::text END FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND NOT EXISTS (SELECT 1 FROM pg_depend dp JOIN pg_extension e ON e.oid=dp.refobjid WHERE dp.objid=p.oid) ORDER BY 2,3 LIMIT 200" "$d")"
        tb="$(pq "SELECT /* zanbug-agent */ '$d', schemaname, relname, n_live_tup, pg_total_relation_size(relid)/1048576 FROM pg_stat_user_tables ORDER BY 5 DESC LIMIT 25" "$d")"
        [ -n "$t" ] && { local j; j="$(printf '%s\n' "$t" | tsv_json "db,schema,table,name,status,function")"; triggers="$triggers$([ "$triggers" != "[" ] && printf ,)${j:1:${#j}-2}"; }
        [ -n "$f" ] && { local j; j="$(printf '%s\n' "$f" | tsv_json "db,schema,name,language,kind")"; functions="$functions$([ "$functions" != "[" ] && printf ,)${j:1:${#j}-2}"; }
        [ -n "$tb" ] && { local j; j="$(printf '%s\n' "$tb" | tsv_json "db,schema,table,rows,size_mb" "rows,size_mb")"; tables="$tables$([ "$tables" != "[" ] && printf ,)${j:1:${#j}-2}"; }
    done <<<"$dbs"
    triggers="$triggers]"; functions="$functions]"; tables="$tables]"
    local cronjobs="null"
    if printf '%s' "$ext" | grep -q '"pg_cron"'; then
        cronjobs="$(pq "SELECT /* zanbug-agent */ jobid, jobname, schedule, database, active, left(command,300) FROM cron.job ORDER BY 1 LIMIT 100" | tsv_json "id,name,schedule,db,active,command" "id")"
    fi
    printf '{"version":%s,"settings":%s,"activity":%s,"extensions":%s,"databases":%s,"triggers":%s,"functions":%s,"tables":%s,"pg_cron":%s}' \
        "$(jstr "$ver")" "${settings:-null}" "${activity:-null}" "${ext:-null}" "${dbs_json:-null}" "$triggers" "$functions" "$tables" "$cronjobs"
}
inventory_json() {
    local parts="" s
    if [ "$MONITOR_SERVER" = "1" ]; then parts="\"server\":$(inventory_server_json)"; fi
    if [ "$MONITOR_MYSQL" = "1" ]; then s="$(inventory_mysql_json)"; parts="${parts:+$parts,}\"mysql\":$s"; fi
    if [ "$MONITOR_PGSQL" = "1" ]; then s="$(inventory_pgsql_json)"; parts="${parts:+$parts,}\"postgres\":$s"; fi
    printf '{%s,"taken_at":"%s"}' "$parts" "$(now_iso)"
}

# ------------------------------------------------------------- transport ----
modules_json() {
    local m=""
    [ "$MONITOR_SERVER" = "1" ] && m="\"server\""
    [ "$MONITOR_MYSQL" = "1" ] && m="${m:+$m,}\"mysql\""
    [ "$MONITOR_PGSQL" = "1" ] && m="${m:+$m,}\"postgres\""
    [ "$MONITOR_REDIS" = "1" ] && m="${m:+$m,}\"redis\""
    printf '[%s]' "$m"
}
# POST $2 (json) to $1 (path). Sets HTTP_CODE and RESP. Returns 0 on 2xx.
post_json() {
    local tmp; tmp="$(mktemp)"
    HTTP_CODE="$(curl -sS -m 20 -o "$tmp" -w '%{http_code}' -X POST "$ZANBUG_HOST$1" \
        -H "X-Zanbug-Key: $ZANBUG_API_KEY" -H "Content-Type: application/json" -H "User-Agent: $UA" --data-binary "$2" 2>>"$LOG_FILE")" || HTTP_CODE="000"
    RESP="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
    case "$HTTP_CODE" in 2*) return 0;; *) return 1;; esac
}
apply_config() {
    local v
    v="$(cfg_num sample_s "$1")"; [ -n "$v" ] && SAMPLE_S="${v%.*}"
    v="$(cfg_num heartbeat_s "$1")"; [ -n "$v" ] && HEARTBEAT_S="${v%.*}"
    v="$(cfg_num top_n "$1")"; [ -n "$v" ] && TOP_N="${v%.*}"
    v="$(cfg_num spike_cooldown_s "$1")"; [ -n "$v" ] && SPIKE_COOLDOWN_S="${v%.*}"
    v="$(cfg_num inventory_s "$1")"; [ -n "$v" ] && INVENTORY_S="${v%.*}"
    v="$(cfg_num redis_scan_s "$1")"; [ -n "$v" ] && REDIS_SCAN_S="${v%.*}"
    v="$(cfg_num load_per_cpu "$1")"; [ -n "$v" ] && TH_LOAD="$v"
    v="$(cfg_num cpu_pct "$1")"; [ -n "$v" ] && TH_CPU="${v%.*}"
    v="$(cfg_num mem_pct "$1")"; [ -n "$v" ] && TH_MEM="${v%.*}"
    v="$(cfg_num disk_pct "$1")"; [ -n "$v" ] && TH_DISK="${v%.*}"
    v="$(cfg_num iowait_pct "$1")"; [ -n "$v" ] && TH_IOWAIT="${v%.*}"
    [ "$SAMPLE_S" -lt 2 ] && SAMPLE_S=2; [ "$HEARTBEAT_S" -lt 15 ] && HEARTBEAT_S=15; [ "$REDIS_SCAN_S" -lt 300 ] && REDIS_SCAN_S=300
    return 0
}
# Send everything buffered (+ optional inventory). Buffer is one JSON object per line.
BUF="$STATE_DIR/samples.jsonl"; QBUF="$STATE_DIR/queries.jsonl"; QSEND="$STATE_DIR/queries.sending"; INV_HASH="$STATE_DIR/inventory.md5"; INV_SENT="$STATE_DIR/inventory.sent"
flush_samples() {
    local inv="${1:-}" samples payload
    [ -s "$BUF" ] || [ -n "$inv" ] || return 0
    samples="$(tail -n 120 "$BUF" 2>/dev/null | paste -sd, -)"
    payload="$(printf '{"host":%s,"agent_version":"%s","modules":%s,"os":%s,"cpus":%s,"mem_total_mb":%s%s%s,"samples":[%s]}' \
        "$(jstr "$HOST_NAME")" "$AGENT_VERSION" "$(modules_json)" "$(jstr "$OS_NAME")" "$CPUS" "$MEM_TOTAL_MB" "${inv:+,\"inventory\":$inv}" "${REDIS_EXTRA:+,\"redis\":$REDIS_EXTRA}" "$samples")"
    if post_json /api/ingest/agent "$payload"; then
        : > "$BUF"; apply_config "$RESP"; date +%s > "$STATE_DIR/last_push"
        [ -n "$REDIS_EXTRA" ] && redis_after_push "$RESP"
        [ -n "$inv" ] && date +%s > "$INV_SENT"
        dbg "pushed $(printf '%s' "$RESP" | sed -n 's/.*"received":\([0-9]*\).*/\1/p') samples, sample_s=$SAMPLE_S heartbeat_s=$HEARTBEAT_S"
        return 0
    fi
    log "push failed HTTP $HTTP_CODE: $(printf '%s' "$RESP" | head -c 200)"
    case "$HTTP_CODE" in 429) ;; 4[0-9][0-9])
        # rejected by the API (bad key / invalid payload): retrying the same lines forever is pointless
        log "dropping $(wc -l < "$BUF" | tr -d ' ') buffered sample(s) rejected by the API"; : > "$BUF"; return 1;; esac
    # keep at most 120 buffered samples while the API is unreachable
    if [ "$(wc -l < "$BUF")" -gt 120 ]; then tail -n 120 "$BUF" > "$BUF.tmp" && mv "$BUF.tmp" "$BUF"; fi
    return 1
}
# Slow-log lines collected by the tailers → POST /api/ingest/queries (≤100 per call).
flush_queries() {
    [ -s "$QBUF" ] || [ -s "$QSEND" ] || return 0
    # the tailers append by name (open/close per line), so an atomic mv is race-free
    if [ -s "$QBUF" ]; then mv "$QBUF" "$QBUF.tmp" && cat "$QBUF.tmp" >> "$QSEND" && rm -f "$QBUF.tmp"; fi
    local n
    while [ -s "$QSEND" ]; do
        n="$(head -n 100 "$QSEND" | wc -l)"
        if post_json /api/ingest/queries "{\"queries\":[$(head -n 100 "$QSEND" | paste -sd, -)]}"; then
            sed -i '1,100d' "$QSEND"; dbg "pushed $n slow-log queries"
        else
            log "queries push failed HTTP $HTTP_CODE"
            if [ "$(wc -l < "$QSEND")" -gt 1000 ]; then tail -n 1000 "$QSEND" > "$QSEND.t" && mv "$QSEND.t" "$QSEND"; fi
            return 1
        fi
    done
}
maybe_inventory() {
    local force="${1:-0}" last_sent=0 inv h old
    [ -f "$INV_SENT" ] && last_sent="$(cat "$INV_SENT")"
    if [ "$force" != "1" ] && [ $(( $(date +%s) - last_sent )) -lt "$INVENTORY_S" ]; then return 1; fi
    # hash ignores counters that change every minute (uptime, row counts, sizes, status) so the inventory is not resent every 5 min
    inv="$(inventory_json)"; h="$(printf '%s' "$inv" | sed -E 's/"(uptime_s|rows|size_mb|count)":[0-9.]+//g; s/"taken_at":"[^"]*"//; s/"(status|activity|tables)":\[[^]]*\]//g' | md5sum | cut -c1-32)"; old="$(cat "$INV_HASH" 2>/dev/null || true)"
    if [ "$h" = "$old" ] && [ "$force" != "1" ] && [ $(( $(date +%s) - last_sent )) -lt 86400 ]; then
        date +%s > "$INV_SENT"; return 1   # unchanged: check again in INVENTORY_S, resend daily anyway
    fi
    printf '%s' "$h" > "$INV_HASH"; PENDING_INVENTORY="$inv"; return 0
}

# ---------------------------------------------------------- slow-log tail ----
# MySQL: blocks of "# Time / # User@Host / # Query_time ... / SET timestamp=; sql".
# Emitted when the next block starts. Writes one JSON per query to $QBUF.
mysql_slowlog_path() {
    [ -n "$MYSQL_SLOW_LOG" ] && { printf '%s' "$MYSQL_SLOW_LOG"; return; }
    local f d; f="$(mq "SELECT @@slow_query_log_file")"; d="$(mq "SELECT @@datadir")"
    [ -z "$f" ] && return 1
    case "$f" in /*) printf '%s' "$f";; *) printf '%s%s' "${d%/}/" "$f";; esac
}
# Parser: slow-log text on stdin → one JSON per query appended to $QBUF.
#  · `use db;` is written by mysqld only when the schema differs from the LAST ENTRY WRITTEN
#    TO THE LOG (File_query_log::write_slow keeps one `db` per log file, not per connection;
#    verified on 8.0.40: a second connection on the same schema gets no `use` line). So the
#    schema carries over between entries. The only entries the format cannot attribute are
#    those of connections without a default schema. MariaDB adds "# Thread_id: N  Schema: db"
#    to every entry and that wins when present.
#  · since = epoch: entries stamped before it were already sent (restart re-reads the last
#    MYSQL_BACKLOG_LINES lines) and are skipped; the newest stamp emitted is kept in
#    $MYSQL_LAST. Entries older than 7 days are skipped too (the API would stamp them "now").
#  · replay_until = epoch: entries stamped at or before it are marked "replay":true so the
#    API drops an exact duplicate (same statement, second, duration) instead of counting it
#    twice; live entries are never marked, two real runs in the same second both count.
MYSQL_LAST="$STATE_DIR/mysql.last_epoch"
mysql_parse() {
    local since="${1:-0}" replay_until="${2:-0}" stats="${3:-0}" floor
    case "$since" in ''|*[!0-9]*) since=0;; esac
    floor=$(( $(date +%s) - 7*86400 )); [ "$since" -lt "$floor" ] && since=$floor
    TZ=UTC awk $AWK_I -v qbuf="$QBUF" -v hn="$HOST_NAME" -v since="$since" -v replay_until="$replay_until" -v lastf="$MYSQL_LAST" -v stats="$stats" '
    function esc(s,  n,P,i,r){ n=split(s,P,/\\/); r=P[1]; for(i=2;i<=n;i++) r=r "\\\\" P[i]; n=split(r,P,/"/); s=P[1]; for(i=2;i<=n;i++) s=s "\\\"" P[i]; gsub(/\r/,"",s); gsub(/[\001-\037]/," ",s); return s }
    function who(  n,h){ if (db == "") return uh; n = index(uh, " @ "); if (n > 0) { h = substr(uh, n+3); gsub(/^ +| +$/, "", h); return substr(uh, 1, n-1) "@" db (h != "" ? " (" h ")" : "") } return uh "@" db }
    function emit(  ts, replay){
        if (sql != "" && qt != "") {
            seen++
            if (sql ~ /zanbug-agent|bugban-agent/) own++   # legacy: bugban → zanbug (2026-10-07) — an older agent may still tag statements
            else if (epoch != "" && epoch+0 < since+0) old++
            else {
                ts = (epoch != "") ? strftime("%Y-%m-%dT%H:%M:%SZ", epoch, 1) : "";
                replay = (epoch != "" && epoch+0 <= replay_until+0) ? "true" : "false";
                printf "{\"sql\":\"%s\",\"duration_ms\":%d,\"occurred_at\":\"%s\",\"source\":\"mysql-log\",\"command\":\"%s\",\"connection\":\"mysql\",\"replay\":%s,\"context\":{\"db\":\"%s\",\"rows_examined\":%d,\"rows_sent\":%d,\"lock_ms\":%d}}\n",
                    esc(substr(sql,1,5000)), qt*1000, ts, esc(who() " on " hn), replay, esc(db), rex, rsent, lt*1000 >> qbuf; close(qbuf); sent++
                if (epoch != "" && epoch+0 > last+0) { last = epoch+0; printf "%d\n", last > lastf; close(lastf) }
            }
        }
        sql=""; qt=""; uh=""; epoch=""; rex=0; rsent=0; lt=0 }
    BEGIN { last = since }
    /^__ZANBUG_TICK__$/ { if (sql != "") emit(); next }
    /^# Time:/ { emit(); next }
    /^# User@Host:/ { if (sql != "") emit(); uh=$0; sub(/^# User@Host: */,"",uh); sub(/ +Id: .*/,"",uh); gsub(/\[[^]]*\]/,"",uh); gsub(/  +/," ",uh); sub(/ +$/,"",uh); next }
    /^# Thread_id:/ { if (match($0, /Schema: [^ ]*/)) db = substr($0, RSTART+8, RLENGTH-8); next }
    /^# Query_time:/ { for(i=1;i<=NF;i++){ if($i=="Query_time:") qt=$(i+1); if($i=="Lock_time:") lt=$(i+1); if($i=="Rows_sent:") rsent=$(i+1); if($i=="Rows_examined:") rex=$(i+1) } next }
    /^# / { next }
    /^SET timestamp=/ { s=$0; sub(/^SET timestamp=/,"",s); sub(/;.*/,"",s); epoch=s; next }
    /^use / { db=$0; sub(/^use /,"",db); sub(/;$/,"",db); next }
    /^(\/usr|\/opt|Tcp port|Time  )/ { next }
    { sql = (sql=="") ? $0 : sql "\n" $0 }
    END { if (sql != "") emit(); if (stats) printf "entries=%d queued=%d skipped_already_sent_or_old=%d skipped_own=%d\n", seen, sent, old, own > "/dev/stderr" }
    '
}
mysql_tail() {
    local f since n floor; f="$(mysql_slowlog_path)" || { log "mysql: cannot find slow log path"; return; }
    [ "$(mq "SELECT @@slow_query_log")" = "1" ] || log "mysql: slow_query_log is OFF — run: zanbug-agent setup-mysql"
    # After logrotate mysqld may still write into the deleted old inode; FLUSH makes it reopen the file by name.
    mq "FLUSH SLOW LOGS" >/dev/null 2>&1 || true
    until [ -r "$f" ]; do sleep 30; [ -r "$f" ] || dbg "mysql: waiting for $f"; done
    since="$(cat "$MYSQL_LAST" 2>/dev/null || true)"; case "$since" in ''|*[!0-9]*) since=0;; esac
    floor=$(( $(date +%s) - 7*86400 )); [ "$since" -lt "$floor" ] && since=$floor
    n="$MYSQL_BACKLOG_LINES"; case "$n" in ''|*[!0-9]*) n=5000;; esac
    log "mysql: tailing $f (re-reading the last $n lines; entries before $(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$since") are skipped)"
    # rotation watcher: inode changed → FLUSH SLOW LOGS (tail -F already follows the new name)
    ( ino="$(stat -c %i "$f" 2>/dev/null)"
      while kill -0 $$ 2>/dev/null; do sleep 60; n="$(stat -c %i "$f" 2>/dev/null)"
          if [ -n "$n" ] && [ "$n" != "$ino" ]; then ino="$n"; mq "FLUSH SLOW LOGS" >/dev/null 2>&1; log "mysql: slow log rotated → FLUSH SLOW LOGS"; fi
      done ) &
    # feeder: the last N lines (what was logged while the agent was down / before install) +
    # new lines, plus a tick every 2 s so a finished entry is emitted without waiting for the next one
    { tail -n"$n" -F $TP "$f" 2>/dev/null & t=$!
      while kill -0 $$ 2>/dev/null && kill -0 "$t" 2>/dev/null; do sleep 2; echo "__ZANBUG_TICK__"; done
      kill "$t" 2>/dev/null; } | mysql_parse "$since" "$(date +%s)"
}
# PostgreSQL: "... LOG:  duration: 1234.5 ms  statement: SELECT ..." (+ continuation lines).
pg_log_dir() {
    [ -n "$PG_LOG_DIR" ] && { printf '%s' "$PG_LOG_DIR"; return; }
    local coll dir data
    coll="$(pq "SHOW logging_collector")"; dir="$(pq "SHOW log_directory")"; data="$(pq "SHOW data_directory")"
    if [ "$coll" = "on" ] && [ -n "$dir" ]; then case "$dir" in /*) printf '%s' "$dir";; *) printf '%s/%s' "$data" "$dir";; esac; return; fi
    [ -d /var/log/postgresql ] && { printf '/var/log/postgresql'; return; }
    return 1
}
pg_newest_log() { ls -t "$1"/*.log 2>/dev/null | head -n1; }
pg_tail() {
    local dir f t i warned=0
    dir="$(pg_log_dir)" || { log "postgres: cannot find log directory (set PG_LOG_DIR)"; return; }
    [ "$(pq "SHOW log_min_duration_statement")" = "-1" ] && log "postgres: log_min_duration_statement is -1 (off) — run: zanbug-agent setup-postgres"
    while kill -0 $$ 2>/dev/null; do
        f="$(pg_newest_log "$dir")"
        if [ -z "$f" ]; then
            [ "$warned" = 1 ] || { log "postgres: no *.log file in $dir — with logging_collector=off PostgreSQL writes to stderr/journal; run: zanbug-agent setup-postgres (or set PG_LOG_DIR=...)"; warned=1; }
            sleep 60; continue
        fi
        pgtz="$(pq "SHOW log_timezone")"; log "postgres: tailing $f (log_timezone=${pgtz:-?})"
        # feeder: log lines + a tick every 2 s; stops when a newer log file appears (rotation, checked every 30 s)
        { tail -n0 -F $TP "$f" 2>/dev/null & t=$!; i=0
          while kill -0 $$ 2>/dev/null && kill -0 "$t" 2>/dev/null; do
              sleep 2; echo "__ZANBUG_TICK__"; i=$((i+1))
              if [ $((i % 15)) -eq 0 ] && [ "$(pg_newest_log "$dir")" != "$f" ]; then break; fi
          done
          kill "$t" 2>/dev/null; } | TZ=UTC awk $AWK_I -v qbuf="$QBUF" -v hn="$HOST_NAME" -v pgtz="$pgtz" '
        function esc(s,  n,P,i,r){ n=split(s,P,/\\/); r=P[1]; for(i=2;i<=n;i++) r=r "\\\\" P[i]; n=split(r,P,/"/); s=P[1]; for(i=2;i<=n;i++) s=s "\\\"" P[i]; gsub(/\r/,"",s); gsub(/[\001-\037]/," ",s); return s }
        function utc(d, t, z,  cmd, out) {   # "2026-09-08" "13:54:33" "CEST"|"+02" → "2026-09-08T11:54:33Z"
            if (z ~ /^[+-][0-9]/) cmd = "date -u -d \"" d " " t " " z "\" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null";
            else if (pgtz != "") cmd = "e=$(TZ=\"" pgtz "\" date -d \"" d " " t "\" +%s 2>/dev/null) && date -u -d @$e +%Y-%m-%dT%H:%M:%SZ 2>/dev/null";
            else return d "T" t "Z";
            out=""; cmd | getline out; close(cmd); return (out ~ /^[0-9]/) ? out : d "T" t "Z" }
        # legacy: bugban → zanbug (2026-10-07) — skip statements tagged by either agent name
        function emit(){ if (sql != "" && ms != "" && sql !~ /zanbug-agent|bugban-agent/) {
                printf "{\"sql\":\"%s\",\"duration_ms\":%d,\"occurred_at\":\"%s\",\"source\":\"pgsql-log\",\"command\":\"%s\",\"connection\":\"pgsql\"}\n", esc(substr(sql,1,5000)), ms, ts, esc(uh " on " hn) >> qbuf; close(qbuf) }
            sql=""; ms="" }
        /^__ZANBUG_TICK__$/ { if (sql != "") emit(); next }
        /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
            emit();
            if (match($0, /duration: [0-9.]+ ms  (statement|execute [^:]*): /)) {
                head=substr($0,1,RSTART-1); rest=substr($0,RSTART+RLENGTH);
                d=substr($0,RSTART); sub(/^duration: /,"",d); sub(/ ms.*/,"",d); ms=d+0;
                ts=utc($1, substr($2,1,8), $3); uh="";
                if (match(head, /[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+/)) uh=substr(head,RSTART,RLENGTH);
                sql=rest }
            next }
        sql != "" && /^[\t ]/ { l=$0; sub(/^[\t ]+/," ",l); sql=sql l; next }
        { emit() }
        '
    done
}

# ------------------------------------------------------------- commands ----
cmd_setup_mysql() {
    local secs="${1:-1}" cur dir
    [ -n "$(mq "SELECT 1")" ] || die "cannot connect with MYSQL_CMD='$MYSQL_CMD' (set it in $CONF, e.g. mysql --defaults-file=/etc/zanbug/mysql.cnf)"
    $MYSQL_CMD --comments -e "/* zanbug-agent */ SET GLOBAL slow_query_log = ON; /* zanbug-agent */ SET GLOBAL long_query_time = $secs; /* zanbug-agent */ SET GLOBAL log_output = 'FILE'; /* zanbug-agent */ SET GLOBAL log_slow_admin_statements = ON;" || die "SET GLOBAL failed (need SUPER / SYSTEM_VARIABLES_ADMIN)"
    cur="$(mysql_slowlog_path)"
    # directories the running engine actually includes (my.cnf !includedir), then the usual suspects.
    # On MariaDB /etc/mysql/mysql.conf.d may exist as a leftover but is NOT included → a file there is dead.
    for dir in $(grep -h '^!includedir' /etc/mysql/my.cnf /etc/my.cnf /etc/mysql/mariadb.cnf 2>/dev/null | awk '{print $2}' | sed 's:/$::') /etc/mysql/conf.d /etc/my.cnf.d /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d; do
        [ -d "$dir" ] || continue
        # legacy: bugban → zanbug (2026-10-07) — replace the drop-in written under the old name
        [ -f "$dir/zz-bugban-slow.cnf" ] && rm -f "$dir/zz-bugban-slow.cnf"
        printf '# written by zanbug-agent setup-mysql — keeps the slow log on across restarts\n[mysqld]\nslow_query_log = 1\nlong_query_time = %s\nlog_output = FILE\nlog_slow_admin_statements = 1\nslow_query_log_file = %s\n' "$secs" "$cur" > "$dir/zz-zanbug-slow.cnf"
        echo "persisted in $dir/zz-zanbug-slow.cnf"; break
    done
    echo "slow_query_log=ON, long_query_time=${secs}s, file: $cur"
    echo "The agent picks it up on its next start: systemctl restart zanbug-agent"
}
cmd_setup_postgres() {
    local ms="${1:-1000}" prefix
    [ -n "$(pq "SELECT 1")" ] || die "cannot connect with PG_CMD='$PG_CMD' (set it in $CONF)"
    pq "ALTER SYSTEM SET log_min_duration_statement = '${ms}ms'" >/dev/null || die "ALTER SYSTEM failed (need superuser)"
    prefix="$(pq "SHOW log_line_prefix")"
    case "$prefix" in *%u*) ;; *) pq "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d '" >/dev/null && echo "log_line_prefix set to '%m [%p] %q%u@%d ' (user@db in each line)";; esac
    pq "SELECT pg_reload_conf()" >/dev/null
    echo "log_min_duration_statement=${ms}ms, log dir: $(pg_log_dir || echo '? set PG_LOG_DIR')"
    if [ "$(pq "SHOW logging_collector")" != "on" ] && [ -z "$(pg_newest_log "$(pg_log_dir 2>/dev/null)" 2>/dev/null)" ]; then
        echo "WARNING: logging_collector=off and no *.log file found — the agent can only tail files. Either:"
        echo "  psql: ALTER SYSTEM SET logging_collector = on;  then restart PostgreSQL (needs a restart, not reload)"
        echo "  or set PG_LOG_DIR=/path/with/postgres/logs in $CONF"
    fi
    echo "The agent picks it up on its next start: systemctl restart zanbug-agent"
}
# One-off: push every entry of a slow-log file (default: the live one; a rotated
# slow.log.1 works too). Entries older than 7 days are skipped, exact duplicates of
# what was already sent are dropped by the API ("replay").
cmd_backfill() {
    local f="${1:-}"
    [ -n "$ZANBUG_API_KEY" ] || die "ZANBUG_API_KEY missing in $CONF"
    [ -n "$f" ] || f="$(mysql_slowlog_path)" || die "cannot find the MySQL slow log — pass it: zanbug-agent backfill /var/log/mysql/slow.log"
    [ -r "$f" ] || die "cannot read $f"
    mkdir -p "$STATE_DIR"; touch "$QBUF"
    echo "parsing $f"
    mysql_parse 0 "$(date +%s)" 1 < "$f"
    flush_queries && echo "pushed → $ZANBUG_HOST (HTTP $HTTP_CODE)" || { echo "push failed HTTP $HTTP_CODE — left in $QSEND, the running agent retries it"; exit 1; }
}
cmd_test() {
    [ -n "$ZANBUG_API_KEY" ] || die "ZANBUG_API_KEY missing in $CONF"
    mkdir -p "$STATE_DIR"
    local payload
    payload="$(printf '{"host":%s,"agent_version":"%s","modules":%s,"os":%s,"cpus":%s,"mem_total_mb":%s,"samples":[%s]}' \
        "$(jstr "$HOST_NAME")" "$AGENT_VERSION" "$(modules_json)" "$(jstr "$OS_NAME")" "$CPUS" "$MEM_TOTAL_MB" "$(sample_json heartbeat)")"
    if post_json /api/ingest/agent "$payload"; then
        apply_config "$RESP"
        echo "OK  host=$HOST_NAME modules=$(modules_json) → $ZANBUG_HOST (HTTP $HTTP_CODE)"
        echo "    config from panel: sample every ${SAMPLE_S}s, heartbeat ${HEARTBEAT_S}s, spike when load > ${TH_LOAD}×${CPUS} cpus | cpu > ${TH_CPU}% | ram > ${TH_MEM}% | disk > ${TH_DISK}%"
        [ "$MONITOR_MYSQL" = "1" ] && { [ -n "$(mq "SELECT 1")" ] && echo "    mysql: connected, slow_query_log=$(mq "SELECT @@slow_query_log") long_query_time=$(mq "SELECT @@long_query_time") file=$(mysql_slowlog_path)" || echo "    mysql: NOT reachable with MYSQL_CMD='$MYSQL_CMD'"; }
        [ "$MONITOR_REDIS" = "1" ] && { [ "$(rcli ping)" = "PONG" ] && echo "    redis: connected v$(rcli info server | tr -d '\r' | sed -n 's/^redis_version://p'), $(rcli dbsize) keys in db0, slowlog-log-slower-than=$(rcli config get slowlog-log-slower-than | tail -n1)µs, cleanup $([ "$REDIS_ALLOW_ACTIONS" = "1" ] && echo allowed || echo 'off (REDIS_ALLOW_ACTIONS=0)')" || echo "    redis: NOT reachable with REDIS_CLI='$REDIS_CLI': $($REDIS_CLI ping </dev/null 2>&1 | head -n1)"; }
        [ "$MONITOR_PGSQL" = "1" ] && { [ -n "$(pq "SELECT 1")" ] && echo "    postgres: connected, log_min_duration_statement=$(pq "SHOW log_min_duration_statement") dir=$(d="$(pg_log_dir 2>/dev/null)"; if [ -z "$d" ]; then echo '? (set PG_LOG_DIR)'; elif [ -z "$(pg_newest_log "$d")" ]; then echo "$d (no *.log yet — logging_collector=$(pq "SHOW logging_collector"))"; else echo "$d"; fi)" || echo "    postgres: NOT reachable with PG_CMD='$PG_CMD'"; }
        return 0
    fi
    echo "FAILED HTTP $HTTP_CODE: $(printf '%s' "$RESP" | head -c 300)"; return 1
}
cmd_status() {
    echo "zanbug-agent $AGENT_VERSION  conf=$CONF  host=$HOST_NAME  modules=$(modules_json)"
    # legacy: bugban → zanbug (2026-10-07) — show the old unit while it is still the one running
    echo "service: $(systemctl is-active zanbug-agent 2>/dev/null || systemctl is-active bugban-agent 2>/dev/null || echo 'not installed')"
    [ -f "$STATE_DIR/last_push" ] && echo "last push: $(date -u -d "@$(cat "$STATE_DIR/last_push")" +%Y-%m-%dT%H:%M:%SZ) ($(( $(date +%s) - $(cat "$STATE_DIR/last_push") ))s ago)"
    [ -f "$INV_SENT" ] && echo "last inventory: $(date -u -d "@$(cat "$INV_SENT")" +%Y-%m-%dT%H:%M:%SZ)"
    echo "buffered: $( [ -f "$BUF" ] && wc -l < "$BUF" || echo 0) samples, $( [ -f "$QBUF" ] && wc -l < "$QBUF" || echo 0) queries"
    [ "$MONITOR_REDIS" = "1" ] && echo "redis: last key scan $( [ -f "$STATE_DIR/redis.scan_at" ] && date -u -d "@$(cat "$STATE_DIR/redis.scan_at")" +%Y-%m-%dT%H:%M:%SZ || echo never) (every ${REDIS_SCAN_S}s), slowlog cursor $(cat "$STATE_DIR/redis.last_slow" 2>/dev/null || echo -1)"
    [ -f "$LOG_FILE" ] && { echo "--- log"; tail -n 5 "$LOG_FILE"; }
    return 0
}
# ------------------------------------------------------------------ redis ----
# Keys never leave the box raw: rate-limiter / session keys carry e-mail|IP.
# Same order as RedisIngest::normalizeKey() and the slowlog Lua below.
REDIS_NORM='s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/{email}/g
s/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/{uuid}/g
s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/{ip}/g
s/[0-9a-fA-F]{16,}/{hash}/g
s/[A-Za-z0-9]{24,}/{id}/g
s/[0-9]+/{n}/g'
REDIS_PEEK=0   # `zanbug-agent redis` prints without consuming the pending files
rcli() { $REDIS_CLI "$@" </dev/null 2>/dev/null; }
# one key per line on stdin → "pattern<TAB>key"
redis_norm_pairs() { LC_ALL=C sed -E -e h -e "$REDIS_NORM" -e G -e 's/\n/\t/'; }
# lines "pattern<TAB>key" whose pattern is exactly $1
redis_keys_of() { P="$1" LC_ALL=C awk 'BEGIN{p=ENVIRON["P"]} { i=index($0,"\t"); if (i && substr($0,1,i-1)==p) print substr($0,i+1) }'; }

# INFO allowlist → "instance":…,"info":{…},"keyspace":[…] (empty when Redis is unreachable)
redis_info_part() {
    rcli info | tr -d '\r' | awk -F: \
        -v nums="uptime_in_seconds,connected_clients,blocked_clients,used_memory,used_memory_peak,used_memory_rss,maxmemory,mem_fragmentation_ratio,total_commands_processed,instantaneous_ops_per_sec,keyspace_hits,keyspace_misses,evicted_keys,expired_keys,rejected_connections,aof_enabled,connected_slaves,rdb_changes_since_last_save" \
        -v strs="redis_version,role,maxmemory_policy,rdb_last_bgsave_status,os" '
    BEGIN{ n=split(nums,N,","); for(i=1;i<=n;i++) isn[N[i]]=1; m=split(strs,S,","); for(i=1;i<=m;i++) iss[S[i]]=1 }
    /^db[0-9]+:/ { d=substr($1,3); c=split($2,P,","); k=e=t=0
        for(i=1;i<=c;i++){ split(P[i],KV,"="); if(KV[1]=="keys")k=KV[2]+0; else if(KV[1]=="expires")e=KV[2]+0; else if(KV[1]=="avg_ttl")t=KV[2]+0 }
        if (nks < 16) { ks=ks (nks?",":"") sprintf("{\"db\":%d,\"keys\":%.0f,\"expires\":%.0f,\"avg_ttl\":%.0f}",d,k,e,t); nks++ }
        next }
    NF>=2 { key=$1; v=substr($0,length($1)+2); seen=1
        if (key=="tcp_port") port=v
        if (isn[key] && v ~ /^[0-9]+(\.[0-9]+)?$/) out=out (out==""?"":",") "\"" key "\":" v
        else if (iss[key]) { gsub(/["\\]/,"",v); gsub(/[\001-\037]/," ",v); out=out (out==""?"":",") "\"" key "\":\"" substr(v,1,60) "\"" } }
    END{ if (seen) printf "\"instance\":\"redis:%s\",\"info\":{%s},\"keyspace\":[%s]", (port ~ /^[0-9]+$/ ? port : "?"), out, ks }'
}

# New SLOWLOG entries since the last pushed id. Values never travel: EVAL → head of
# the script + normalized first key, other commands → normalized first key.
# The agent's own scripts start with "--zanbug-agent" (or the pre-rename "--bugban-agent") and are skipped.
REDIS_SLOW_LUA='local last=tonumber(ARGV[1]) local minTs=tonumber(ARGV[2])
local function norm(s)
  s=string.gsub(s,"[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+","{email}")
  s=string.gsub(s,string.rep("%x",8).."%-"..string.rep("%x",4).."%-"..string.rep("%x",4).."%-"..string.rep("%x",4).."%-"..string.rep("%x",12),"{uuid}")
  s=string.gsub(s,"%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?","{ip}")
  s=string.gsub(s,string.rep("%x",16).."%x*","{hash}")
  s=string.gsub(s,string.rep("%w",24).."%w*","{id}")
  s=string.gsub(s,"%d+","{n}")
  return s
end
local r=redis.call("slowlog","get",128)
local maxId=-1
for _,x in ipairs(r) do if x[1]>maxId then maxId=x[1] end end
if maxId<last then last=-1 end
local out={}
for _,x in ipairs(r) do
  local a=x[4]
  if x[1]>last and x[2]>=minTs and a and a[1] then
    local cmd=string.upper(tostring(a[1])) local tgt="" local own=false
    if cmd=="EVAL" or cmd=="EVALSHA" then
      local sc=tostring(a[2] or "")
      own=string.sub(sc,1,14)=="--zanbug-agent" or string.sub(sc,1,14)=="--bugban-agent"
      tgt=string.sub(string.gsub(sc,"%s+"," "),1,80)
      if (tonumber(a[3] or 0) or 0)>0 and a[4] then tgt=tgt.." | "..norm(tostring(a[4])) end
    elseif a[2] then tgt=norm(tostring(a[2])) end
    if not own then
      table.insert(out,{id=x[1],ts=x[2],us=x[3],cmd=string.sub(cmd,1,40),target=string.sub(tgt,1,200),client=tostring(x[5] or "")})
    end
  end
end
return "{\"max\":"..maxId..",\"entries\":"..cjson.encode(out).."}"'
# → ,"slowlog":[…]  or  ,"error":"slowlog: …"
redis_slowlog_part() {
    local last r max entries
    last="$(cat "$STATE_DIR/redis.last_slow" 2>/dev/null)"; case "$last" in ''|*[!0-9-]*) last=-1;; esac
    r="$($REDIS_CLI eval "$REDIS_SLOW_LUA" 0 "$last" "$(( $(date +%s) - 7*86400 ))" </dev/null 2>&1 | tr -d '\r')"
    case "$r" in
        '{"max":'*) ;;
        *) printf ',"error":%s' "$(jstr "slowlog: $(printf '%s' "$r" | head -n1 | cut -c1-200)")"; return 0;;
    esac
    max="${r#\{\"max\":}"; max="${max%%,*}"
    entries="${r#*,\"entries\":}"; entries="${entries%\}}"
    [ "$entries" = "{}" ] && entries="[]"
    # remembered only after the push succeeds (redis_after_push)
    [ "$REDIS_PEEK" = "1" ] || printf '%s' "$max" > "$STATE_DIR/redis.last_slow.pending"
    printf ',"slowlog":%s' "$entries"
}

# The "redis" block of a heartbeat push (RedisIngest::prepare).
redis_json() {
    local body allow=false g="$STATE_DIR/redis.groups" rs="$STATE_DIR/redis.results" extra=""
    [ "$REDIS_ALLOW_ACTIONS" = "1" ] && allow=true
    body="$(redis_info_part)"
    if [ -n "$body" ]; then
        body="$body$(redis_slowlog_part)"
    else
        body="\"error\":$(jstr "redis not reachable: $($REDIS_CLI ping </dev/null 2>&1 | tr -d '\r' | head -n1 | cut -c1-200)")"
    fi
    if [ "$REDIS_PEEK" != "1" ]; then
        # a scan finished since the last push → it replaces whatever was waiting
        [ -s "$g.json" ] && mv -f "$g.json" "$g.sending"
        [ -s "$rs.sending" ] || { [ -s "$rs.jsonl" ] && mv -f "$rs.jsonl" "$rs.sending"; }
        [ -s "$g.sending" ] && extra=",\"groups\":$(cat "$g.sending")"
        [ -s "$rs.sending" ] && extra="$extra,\"action_results\":[$(head -n 20 "$rs.sending" | paste -sd, -)]"
    fi
    printf '{%s,"allow_actions":%s%s}' "$body" "$allow" "$extra"
}

# Sampled key groups per db → $STATE_DIR/redis.groups.json (sent with the next heartbeat).
REDIS_SAMPLE_LUA='--zanbug-agent
local o={sampled=0,ttl_none=0,ttl_n=0,ttl_sum=0,mem_sum=0,types={}}
for _,k in ipairs(KEYS) do
  local t=redis.call("type",k)
  t=type(t)=="table" and t.ok or t
  if t~="none" then
    o.sampled=o.sampled+1
    o.types[t]=(o.types[t] or 0)+1
    local p=redis.call("pttl",k)
    if p==-1 then o.ttl_none=o.ttl_none+1 elseif p>0 then o.ttl_n=o.ttl_n+1 o.ttl_sum=o.ttl_sum+math.floor(p/1000) end
    local ok,m=pcall(redis.call,"memory","usage",k)
    if ok and type(m)=="number" then o.mem_sum=o.mem_sum+m end
  end
end
return cjson.encode(o)'
redis_scan_groups() {
    local pairs="$STATE_DIR/redis.scan.pairs" out="$STATE_DIR/redis.groups.tmp" dbs="" d db total scanned groups cnt pat j keys
    for d in $(rcli info keyspace | tr -d '\r' | sed -n 's/^db\([0-9]*\):keys=\([0-9]*\).*/\1:\2/p' | head -n 16); do
        db="${d%%:*}"; total="${d#*:}"; [ "$total" -gt 0 ] 2>/dev/null || continue
        rcli -n "$db" --scan | head -n "$REDIS_SCAN_KEYS" | redis_norm_pairs > "$pairs"
        scanned="$(wc -l < "$pairs" | tr -d ' ')"
        groups=""
        while IFS=$'\t' read -r cnt pat; do
            [ -n "$pat" ] || continue
            mapfile -t keys < <(redis_keys_of "$pat" < "$pairs" | head -n 20)
            j=""
            [ "${#keys[@]}" -gt 0 ] && j="$($REDIS_CLI -n "$db" eval "$REDIS_SAMPLE_LUA" "${#keys[@]}" "${keys[@]}" </dev/null 2>/dev/null | tr -d '\r')"
            case "$j" in '{'*'}') ;; *) j='{"sampled":0}';; esac
            groups="${groups:+$groups,}{\"pattern\":$(jstr "$pat"),\"count\":$cnt,${j#\{}"
        done < <(cut -f1 "$pairs" | LC_ALL=C sort | uniq -c | sort -rn | head -n 50 | sed -E 's/^ *([0-9]+) /\1\t/')
        dbs="${dbs:+$dbs,}{\"db\":$db,\"scanned\":$scanned,\"total\":$total,\"groups\":[$groups]}"
    done
    rm -f "$pairs"; unset keys
    printf '{"dbs":[%s]}' "$dbs" > "$out" && mv -f "$out" "$STATE_DIR/redis.groups.json"
}
redis_maybe_scan() {
    local now last pidf="$STATE_DIR/redis.scan.pid"
    now=$(date +%s); last="$(cat "$STATE_DIR/redis.scan_at" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0;; esac
    [ $((now - last)) -ge "$REDIS_SCAN_S" ] || return 0
    [ -s "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null && return 0
    printf '%s' "$now" > "$STATE_DIR/redis.scan_at"
    ( printf '%s' "$BASHPID" > "$pidf"; renice -n 10 "$BASHPID" >/dev/null 2>&1; redis_scan_groups; rm -f "$pidf" ) &
}

redis_result() {   # id status deleted error
    printf '{"id":%s,"status":"%s","deleted":%s,"error":%s}\n' "$1" "$2" "$(jnum "$3")" "$(jstr "$4")" >> "$STATE_DIR/redis.results.jsonl"
}
# Delete one key group the panel asked for. Only keys whose NORMALIZED name equals
# the pattern are touched (the glob is wider: "user:{n}" → "user:*").
redis_action() {
    local id="$1" db="$2" pat="$3" pre glob tmp out n err cmd=unlink major
    if [ "$REDIS_ALLOW_ACTIONS" != "1" ]; then redis_result "$id" disabled "" "cleanup is off on this server (REDIS_ALLOW_ACTIONS=1 in agent.conf)"; return 0; fi
    pre="${pat%%\{*}"
    if [ -z "$pat" ] || [ "${#pre}" -lt 3 ]; then redis_result "$id" failed "" "pattern needs a literal prefix of 3+ characters"; return 0; fi
    glob="$(printf '%s' "$pat" | sed -e 's/[][*?\\]/\\&/g' -e 's/{\(email\|uuid\|ip\|hash\|id\|n\)}/*/g')"
    tmp="$STATE_DIR/redis.act.$id.keys"
    rcli -n "$db" --scan --pattern "$glob" | redis_norm_pairs | redis_keys_of "$pat" | head -n 100000 > "$tmp"
    major="$(rcli info server | tr -d '\r' | sed -n 's/^redis_version:\([0-9]*\).*/\1/p')"
    [ "${major:-4}" -lt 4 ] 2>/dev/null && cmd=del
    out="$(xargs -r -d '\n' -n 500 $REDIS_CLI -n "$db" "$cmd" < "$tmp" 2>&1 | tr -d '\r')"
    rm -f "$tmp"
    n="$(printf '%s\n' "$out" | awk '/^\(integer\) [0-9]+$/{s+=$2;next} /^[0-9]+$/{s+=$1} END{printf "%d", s}')"
    err="$(printf '%s\n' "$out" | grep -v -E '^(\(integer\) )?[0-9]+$' | grep -v '^$' | head -n1 | cut -c1-200)"
    if [ -n "$err" ] && [ "$n" = "0" ]; then redis_result "$id" failed 0 "$err"; else redis_result "$id" done "$n" "$err"; fi
    log "redis cleanup #$id db$db: $n key(s) deleted${err:+ ($err)}"
}
# After a successful push: commit the slowlog cursor, drop what was delivered,
# start the cleanup actions the API handed back ("redis_do":"id:db:b64 …").
redis_after_push() {
    local cmds c id rest db pat
    [ -f "$STATE_DIR/redis.last_slow.pending" ] && mv -f "$STATE_DIR/redis.last_slow.pending" "$STATE_DIR/redis.last_slow"
    rm -f "$STATE_DIR/redis.groups.sending" "$STATE_DIR/redis.results.sending"
    cmds="$(printf '%s' "$1" | sed -n 's/.*"redis_do":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')"
    for c in $cmds; do
        id="${c%%:*}"; rest="${c#*:}"; db="${rest%%:*}"
        case "$id" in ''|*[!0-9]*) continue;; esac
        case "$db" in ''|*[!0-9]*) continue;; esac
        [ -e "$STATE_DIR/redis.act.$id" ] && continue   # re-sent while still running / already done
        : > "$STATE_DIR/redis.act.$id"
        pat="$(printf '%s' "${rest#*:}" | base64 -d 2>/dev/null)"
        ( redis_action "$id" "$db" "$pat" ) &
    done
    find "$STATE_DIR" -maxdepth 1 -name 'redis.act.*' ! -name '*.keys' -mtime +0 -delete 2>/dev/null
    return 0
}
# ------------------------------------------------------------------ exec ----
# `zanbug-agent exec [--name NAME] -- cmd args...` — run a cron job / script and
# report it as one command_runs row when it ends. The job itself is never changed:
# stdout untouched, stderr passed through (a copy of the tail is kept for
# meta.error), the exit code is returned as is. Reporting is best-effort and
# silent (cron would mail anything we print): short timeout, errors → agent log.
ms_now() { local t; t="$(date +%s%3N 2>/dev/null)"; case "$t" in *N|'') echo $(( $(date +%s) * 1000 ));; *) echo "$t";; esac; }
cmd_exec() {
    local name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="${2:-}"; shift; [ $# -gt 0 ] && shift;;
            --name=*) name="${1#*=}"; shift;;
            --) shift; break;;
            *) break;;
        esac
    done
    [ $# -gt 0 ] || { echo "usage: zanbug-agent exec [--name NAME] -- command [args...]" >&2; exit 2; }
    # nothing to report to → behave exactly like the bare command
    { [ -n "$ZANBUG_API_KEY" ] && have curl; } || exec "$@"
    [ -n "$name" ] || name="$*"
    name="${name:0:300}"
    local elog="$LOG_FILE"; { : >> "$elog"; } 2>/dev/null || elog=/dev/null
    local tmpd errf memf rc run_id started t0 t1 cpu="" mem="" err=""
    tmpd="${TMPDIR:-/tmp}"; [ -d /dev/shm ] && [ -w /dev/shm ] && tmpd=/dev/shm
    errf="$(mktemp "$tmpd/zanbug-exec.XXXXXX" 2>/dev/null)" || errf=""
    memf="$(mktemp "$tmpd/zanbug-exec.XXXXXX" 2>/dev/null)" || memf=""
    run_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf 'sh-%s-%s-%s' "$HOST_NAME" "$$" "$(date +%s%N)")"
    started="$(now_iso)"; t0="$(ms_now)"
    # GNU time gives CPU (user+sys) and peak RSS; busybox/BSD time lack -f/-o → both stay null
    local tm=()
    [ -n "$memf" ] && [ -x /usr/bin/time ] && /usr/bin/time -f %M -o /dev/null true >/dev/null 2>&1 && tm=(/usr/bin/time -f "%U %S %M" -o "$memf")
    if [ -n "$errf" ]; then
        # stdout → fd 3 → our stdout untouched; stderr → tee → our stderr + copy.
        # A pipeline (not >(…)) so tee has finished before the tail is read.
        { ${tm[@]+"${tm[@]}"} "$@" 2>&1 1>&3 3>&- | tee "$errf" >&2 3>&-; rc=${PIPESTATUS[0]}; } 3>&1
    else
        ${tm[@]+"${tm[@]}"} "$@"; rc=$?
    fi
    t1="$(ms_now)"
    # last line: "0.12 0.03 40592" (a non-zero exit adds a "Command exited…" line above it)
    if [ -n "$memf" ] && [ -s "$memf" ]; then
        set -- $(tail -n1 "$memf" 2>/dev/null)
        case "${3:-}" in ''|*[!0-9]*) ;; *) mem=$(( $3 * 1024 ));; esac
        cpu="$(awk -v u="${1:-}" -v s="${2:-}" 'BEGIN{ if (u ~ /^[0-9.]+$/ && s ~ /^[0-9.]+$/) printf "%d", (u+s)*1000 }')"
    fi
    if [ "$rc" != "0" ]; then
        [ -n "$errf" ] && err="$(tail -c 900 "$errf" 2>/dev/null)"
        [ -n "$err" ] || err="exit code $rc"
    fi
    rm -f "$errf" "$memf" 2>/dev/null
    local meta="\"agent\":\"exec\",\"shell\":$(jstr "${SHELL:-}")"
    [ -n "$err" ] && meta="$meta,\"error\":$(jstr "$err")"
    local row
    row="{\"run_id\":$(jstr "${run_id:0:40}"),\"command\":$(jstr "$name"),\"source\":\"cron\",\"runtime\":\"shell\",\"started_at\":\"$started\",\"finished_at\":\"$(now_iso)\",\"duration_ms\":$((t1 - t0)),\"cpu_ms\":$(jnum "$cpu"),\"peak_memory_bytes\":$(jnum "$mem"),\"exit_code\":$rc,\"hostname\":$(jstr "$HOST_NAME"),\"pid\":$$,\"sdk_version\":\"agent-$AGENT_VERSION\",\"meta\":{$meta}}"
    # the project's ingest limit may be busy (SDK, agent backlog) → retry 429/5xx/network twice
    local code try
    for try in 5 20 0; do
        code="$(curl -s -m 10 --connect-timeout 5 -o /dev/null -w '%{http_code}' -X POST "$ZANBUG_HOST/api/ingest/runs" \
            -H "X-Zanbug-Key: $ZANBUG_API_KEY" -H "Content-Type: application/json" -H "User-Agent: $UA" \
            --data-binary "{\"runs\":[$row]}" 2>/dev/null)" || code="000"
        case "$code" in 429|5*|000) [ "$try" -gt 0 ] && sleep "$try";; *) break;; esac
    done
    case "$code" in 2*) ;; *) printf '%s exec: report of "%s" failed (HTTP %s)\n' "$(now_iso)" "$name" "$code" >> "$elog" 2>/dev/null;; esac
    exit "$rc"
}
# kill a process and all its descendants (tail/awk grandchildren of the tailer subshells)
killtree() {
    local p c
    for p in "$@"; do
        for c in $(pgrep -P "$p" 2>/dev/null || ps -o pid= --ppid "$p" 2>/dev/null); do killtree "$c"; done
        kill -TERM "$p" 2>/dev/null
    done
}
cmd_run() {
    [ -n "$ZANBUG_API_KEY" ] || die "ZANBUG_API_KEY missing in $CONF"
    mkdir -p "$STATE_DIR"; touch "$BUF" "$QBUF"
    for b in ps ss; do command -v "$b" >/dev/null 2>&1 || log "warning: '$b' not found — process list / ports will be empty (apt install procps iproute2)"; done
    log "zanbug-agent $AGENT_VERSION starting: host=$HOST_NAME modules=$(modules_json) → $ZANBUG_HOST"
    trap 'log "stopping"; killtree $(jobs -p); wait 2>/dev/null; exit 0' TERM INT
    [ "$MONITOR_MYSQL" = "1" ] && mysql_tail &
    [ "$MONITOR_PGSQL" = "1" ] && pg_tail &
    REDIS_EXTRA=""
    local last_hb=0 last_spike=0 last_q=0 now PENDING_INVENTORY="" first=1 inv_check=0
    SAMPLE_TMP="$STATE_DIR/sample.cur"
    # first sample only primes the CPU/IO counters
    sample_json sample > /dev/null
    while :; do
        sleep "$SAMPLE_S"
        now=$(date +%s)
        if [ "$MONITOR_SERVER" = "1" ]; then
            local s reason
            # NOT s="$(sample_json …)": a command substitution is a subshell, so
            # prev_cpu / LAST_* never reached this shell — cpu_pct was the average
            # since agent start and spike_reason saw the priming sample forever
            # (≤1.3.0: no spikes, flat CPU). A redirect runs in the current shell.
            sample_json sample > "$SAMPLE_TMP"; s="$(cat "$SAMPLE_TMP")"
            reason="$(spike_reason)"
            if [ -n "$reason" ] && [ $((now - last_spike)) -ge "$SPIKE_COOLDOWN_S" ]; then
                log "spike: $reason"
                # same reading, promoted: a second sample_json here would measure a ~0 s interval
                printf '%s,"reason":%s,"processes":%s,"db_processes":%s}\n' "$(printf '%s' "${s%\}}" | sed 's/"kind":"sample"/"kind":"spike"/')" \
                    "$(jstr "$reason")" "$(top_processes_json)" "$(db_processes_json)" >> "$BUF"; last_spike=$now
                flush_samples "$PENDING_INVENTORY" && PENDING_INVENTORY=""; last_hb=$now
            else
                printf '%s\n' "$s" >> "$BUF"
            fi
        fi
        if [ $((now - inv_check)) -ge 300 ] || [ "$first" = "1" ]; then
            inv_check=$now; maybe_inventory "$first" && dbg "inventory changed, sending with next push"
        fi
        if [ $((now - last_hb)) -ge "$HEARTBEAT_S" ] || [ "$first" = "1" ]; then
            [ -s "$BUF" ] || sample_json heartbeat >> "$BUF"
            [ "$MONITOR_REDIS" = "1" ] && { REDIS_EXTRA="$(redis_json)"; redis_maybe_scan; }
            flush_samples "$PENDING_INVENTORY" && PENDING_INVENTORY=""; last_hb=$now; REDIS_EXTRA=""
        fi
        if [ $((now - last_q)) -ge 5 ]; then flush_queries; last_q=$now; fi
        first=0
    done
}

case "${1:-run}" in run|once|inventory|status|backfill|redis) mkdir -p "$STATE_DIR" 2>/dev/null && touch "$BUF" "$QBUF" 2>/dev/null;; esac
case "${1:-run}" in
    run) cmd_run;;
    test) cmd_test;;
    once) mkdir -p "$STATE_DIR"; sample_json sample >/dev/null; sleep 2
          k="${2:-sample}"; r="${3:-manual}"
          case "$k" in sample|spike|heartbeat) ;; *) r="$k"; k="spike";; esac   # `once "deploy"` = spike with reason
          s="$(sample_json "$k" "$r")"; printf '%s\n' "$s" >> "$BUF"; printf '%s\n' "$s"
          flush_samples && echo "pushed → $ZANBUG_HOST (HTTP $HTTP_CODE)" || { echo "push failed HTTP $HTTP_CODE"; exit 1; };;
    inventory) inv="$(inventory_json)"; printf '%s\n' "$inv"
          if [ "${2:-}" = "--send" ]; then mkdir -p "$STATE_DIR"; flush_samples "$inv" && echo "inventory pushed (HTTP $HTTP_CODE)" || { echo "push failed HTTP $HTTP_CODE"; exit 1; }; fi;;
    status) cmd_status;;
    setup-mysql) cmd_setup_mysql "${2:-1}";;
    setup-postgres) cmd_setup_postgres "${2:-1000}";;
    backfill) cmd_backfill "${2:-}";;
    redis) mkdir -p "$STATE_DIR"
          if [ "${2:-}" = "scan" ]; then redis_scan_groups && cat "$STATE_DIR/redis.groups.json"; echo
          else REDIS_PEEK=1 redis_json; echo; fi;;
    exec) shift; cmd_exec "$@";;
    version|--version|-v) echo "$AGENT_VERSION";;
    *) echo "usage: zanbug-agent run|test|once [sample|spike|heartbeat] [reason]|inventory [--send]|status|setup-mysql [seconds]|setup-postgres [ms]|backfill [slow-log file]|redis [scan]|exec [--name NAME] -- command [args...]|version"; exit 2;;
esac
