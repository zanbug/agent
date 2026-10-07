#!/usr/bin/env bash
# zanbug-agent installer — https://zanbug.com/agent/install.sh
#
# One agent, three independent modules. Install only what you need, re-run to
# add another module later (the key and the other modules are kept):
#
#   Server  (load / CPU / RAM / disk / IO / network + what was running on a spike)
#     curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash          # auto: server + every DB engine found
#     curl -fsSL https://zanbug.com/agent/install.sh | sudo bash -s -- --key <API_KEY> --server
#
#   MySQL / MariaDB  (engine's own slow log → Performance tab, processlist on spikes, inventory)
#     curl -fsSL https://zanbug.com/agent/install.sh | sudo bash -s -- --key <API_KEY> --mysql
#
#   PostgreSQL  (log_min_duration_statement lines → Performance tab, pg_stat_activity, inventory)
#     curl -fsSL https://zanbug.com/agent/install.sh | sudo bash -s -- --key <API_KEY> --postgres
#
# Options:
#   --key KEY            project API key (X-Zanbug-Key). Required on first install.
#   --host URL           Zanbug host (default https://zanbug.com — self-hosted panels change it)
#   --server|--mysql|--postgres   modules to switch ON (any combination, cumulative across runs)
#   --no-server|--no-mysql|--no-postgres   switch a module OFF
#   --mysql-cmd 'CMD'    how to reach MySQL as an admin (default: mysql — socket auth as root)
#                        e.g. --mysql-cmd 'mysql --defaults-file=/etc/zanbug/mysql.cnf'
#   --pg-cmd 'CMD'       how to reach PostgreSQL as superuser (default: setpriv/sudo -u postgres psql)
#   --slow-seconds N     MySQL long_query_time to enable when the slow log is off (default 1)
#   --slow-ms N          PostgreSQL log_min_duration_statement when it is off (default 1000)
#   --no-db-setup        do not touch database settings (only tail what is already logged)
#   --hostname NAME      name shown in the panel (default: short hostname)
#   --uninstall          stop + disable the service, remove the binary (keeps /etc/zanbug/agent.conf)
#
# A box still running the pre-rename "bugban-agent" is migrated in place on the first run
# (service, conf, state, log, crontab lines) — nothing is lost, the old name disappears.
#
# Needs: root, bash, curl, systemd. Nothing else — the agent is a single bash script.
set -eu

usage() { cat <<'USAGE'
zanbug-agent installer — one agent, three independent modules (re-run to add one; key + other modules are kept)

  Everything  curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash
              (no flags = --auto: server module + MySQL/MariaDB and/or PostgreSQL if that engine runs on this host)
  Server      curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --server
  MySQL       curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --mysql
  PostgreSQL  curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --postgres
  (the per-project URL from the panel's Server tab already carries --key and --host)

Options:
  --key KEY            project API key (X-Zanbug-Key). Required on first install.
  --host URL           Zanbug host (default https://zanbug.com)
  --auto               detect: server + MySQL/MariaDB + PostgreSQL that actually run here (default when no module flag is given)
  --server|--mysql|--postgres            modules to switch ON (any combination, cumulative across runs)
  --no-server|--no-mysql|--no-postgres   switch a module OFF
  --mysql-cmd 'CMD'    admin MySQL client (default: mariadb or mysql — socket auth as root)
  --pg-cmd 'CMD'       superuser psql (default: setpriv/sudo -u postgres psql)
  --slow-seconds N     MySQL long_query_time to enable when the slow log is off (default 1)
  --slow-ms N          PostgreSQL log_min_duration_statement when it is off (default 1000)
  --no-db-setup        do not touch database settings (only tail what is already logged)
  --hostname NAME      name shown in the panel (default: short hostname)
  --uninstall          stop + disable the service, remove the binary (keeps /etc/zanbug/agent.conf,
                       /var/lib/zanbug-agent and /var/log/zanbug-agent.log); also removes a leftover
                       pre-rename bugban-agent service/binary
  -h, --help

Needs: root, bash, curl, systemd. Nothing else — the agent is a single bash script.
USAGE
}

HOST="https://zanbug.com"; KEY=""; NAME=""
ON=""; OFF=""; AUTO=0; MYSQL_CMD_OPT=""; PG_CMD_OPT=""; SLOW_S=1; SLOW_MS=1000; DB_SETUP=1; UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY="${2:-}"; shift;;
        --key=*) KEY="${1#--key=}";;
        --host) HOST="${2:-}"; shift;;
        --host=*) HOST="${1#--host=}";;
        --hostname) NAME="${2:-}"; shift;;
        --server|--mysql|--postgres) ON="$ON ${1#--}";;
        --auto) AUTO=1;;
        --no-server|--no-mysql|--no-postgres) OFF="$OFF ${1#--no-}";;
        --mysql-cmd) MYSQL_CMD_OPT="${2:-}"; shift;;
        --pg-cmd) PG_CMD_OPT="${2:-}"; shift;;
        --slow-seconds) SLOW_S="${2:-1}"; shift;;
        --slow-ms) SLOW_MS="${2:-1000}"; shift;;
        --no-db-setup) DB_SETUP=0;;
        --uninstall) UNINSTALL=1;;
        -h|--help) usage; exit 0;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2;;
    esac
    shift
done
HOST="${HOST%/}"

BIN=/usr/local/bin/zanbug-agent
CONF_DIR=/etc/zanbug; CONF="$CONF_DIR/agent.conf"
UNIT=/etc/systemd/system/zanbug-agent.service
STATE_DIR=/var/lib/zanbug-agent; LOG_FILE=/var/log/zanbug-agent.log
# legacy: bugban → zanbug (2026-10-07) — where the pre-rename agent lived; migrated/removed below
OLD_NAME=bugban-agent; OLD_BIN=/usr/local/bin/$OLD_NAME; OLD_CONF_DIR=/etc/bugban
OLD_UNIT=/etc/systemd/system/$OLD_NAME.service; OLD_STATE=/var/lib/$OLD_NAME; OLD_LOG=/var/log/$OLD_NAME.log

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root:  curl -fsSL $HOST/agent/install.sh | sudo bash -s -- ..."
command -v curl >/dev/null 2>&1 || die "curl is required (apt install curl / yum install curl)"
command -v systemctl >/dev/null 2>&1 || die "systemd is required (no systemctl found)"

cron_files() {  # every crontab that may call the agent's exec wrapper
    ls /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /var/spool/cron/* 2>/dev/null | sort -u
}

if [ "$UNINSTALL" = "1" ]; then
    systemctl disable --now zanbug-agent 2>/dev/null || true
    rm -f "$UNIT" "$BIN"
    # legacy: bugban → zanbug (2026-10-07) — clean up the old name too
    systemctl disable --now "$OLD_NAME" 2>/dev/null || true
    rm -f "$OLD_UNIT" "$OLD_BIN"
    systemctl daemon-reload
    ok "zanbug-agent removed. Kept (contains the API key!): $CONF, state $STATE_DIR, log $LOG_FILE"
    echo "   clean slate:  rm -rf $CONF_DIR $STATE_DIR $LOG_FILE $OLD_CONF_DIR $OLD_STATE $OLD_LOG"
    exit 0
fi

# ---- 0. legacy: bugban → zanbug (2026-10-07) — migrate a pre-rename install in place ----
# Runs once: afterwards none of the old paths exist. Order matters — the old service is stopped
# first so it cannot write to the state dir while it moves; the state dir (slow-log offsets,
# mysql.last_epoch, pending pushes) is moved, never recreated, so no slow-log entry is sent twice.
if [ -f "$OLD_BIN" ] || [ -f "$OLD_UNIT" ] || [ -f "$OLD_CONF_DIR/agent.conf" ] || [ -d "$OLD_STATE" ]; then
    say "migrating the pre-rename $OLD_NAME install → zanbug-agent"
    if [ -f "$OLD_UNIT" ]; then
        systemctl disable --now "$OLD_NAME" 2>/dev/null || true
        rm -f "$OLD_UNIT"; ok "old service $OLD_NAME stopped + removed"
    fi
    if [ -f "$OLD_CONF_DIR/agent.conf" ]; then
        if [ ! -f "$CONF" ]; then
            mkdir -p "$CONF_DIR"
            ( umask 077; sed -e 's/^BUGBAN_API_KEY=/ZANBUG_API_KEY=/' -e 's/^BUGBAN_HOST=/ZANBUG_HOST=/' \
                -e 's|^ZANBUG_HOST="https\{0,1\}://bugban\.online/\{0,1\}"|ZANBUG_HOST="https://zanbug.com"|' \
                -e "s|$OLD_CONF_DIR/|$CONF_DIR/|g" -e "s/$OLD_NAME/zanbug-agent/g" "$OLD_CONF_DIR/agent.conf" > "$CONF" )
            chmod 600 "$CONF"; ok "conf moved → $CONF (BUGBAN_* keys renamed to ZANBUG_*)"
        else
            warn "both $CONF and $OLD_CONF_DIR/agent.conf exist — keeping $CONF, the old one is dropped"
        fi
        rm -f "$OLD_CONF_DIR/agent.conf"
    fi
    if [ -f "$OLD_CONF_DIR/mysql.cnf" ]; then   # admin credentials referenced by MYSQL_CMD
        mkdir -p "$CONF_DIR"; [ -f "$CONF_DIR/mysql.cnf" ] || mv "$OLD_CONF_DIR/mysql.cnf" "$CONF_DIR/mysql.cnf"; rm -f "$OLD_CONF_DIR/mysql.cnf"
    fi
    [ -d "$OLD_CONF_DIR" ] && rmdir "$OLD_CONF_DIR" 2>/dev/null || true
    if [ -d "$OLD_STATE" ]; then
        if [ -d "$STATE_DIR" ]; then cp -a "$OLD_STATE"/. "$STATE_DIR"/ && rm -rf "$OLD_STATE"; else mv "$OLD_STATE" "$STATE_DIR"; fi
        ok "state moved → $STATE_DIR (slow-log position kept, nothing is re-sent)"
    fi
    if [ -f "$OLD_LOG" ]; then
        if [ -f "$LOG_FILE" ]; then cat "$OLD_LOG" >> "$LOG_FILE" && rm -f "$OLD_LOG"; else mv "$OLD_LOG" "$LOG_FILE"; fi
    fi
    for d in /etc/mysql/conf.d /etc/my.cnf.d /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d; do   # slow-log drop-in written by the old setup-mysql
        [ -f "$d/zz-bugban-slow.cnf" ] || continue
        [ -f "$d/zz-zanbug-slow.cnf" ] && rm -f "$d/zz-bugban-slow.cnf" || mv "$d/zz-bugban-slow.cnf" "$d/zz-zanbug-slow.cnf"
    done
    # crontab lines using the exec wrapper (`bugban-agent exec -- …`) must keep working after the old binary goes
    for cf in $(cron_files); do
        grep -q "$OLD_NAME" "$cf" 2>/dev/null || continue
        sed -i "s|/usr/local/bin/$OLD_NAME|$BIN|g; s|\b$OLD_NAME exec\b|zanbug-agent exec|g" "$cf" && ok "crontab updated: $cf"
    done
    rm -f "$OLD_BIN"
    left="$(grep -ls "$OLD_NAME" $(cron_files) /etc/cron.hourly/* /etc/cron.daily/* 2>/dev/null | tr '\n' ' ')"
    if [ -n "$left" ]; then
        ln -sfn "$BIN" "$OLD_BIN"
        warn "these still mention $OLD_NAME: $left — a compatibility symlink $OLD_BIN → $BIN is kept; fix them and rm it"
    fi
    systemctl daemon-reload
    ok "migration done — no $OLD_NAME paths left"
fi

# ---- 1. the agent itself -------------------------------------------------
say "downloading agent from $HOST/agent/zanbug-agent.sh"
tmp="$(mktemp)"
curl -fsSL "$HOST/agent/zanbug-agent.sh" -o "$tmp" || die "download failed"
head -c 200 "$tmp" | grep -q 'zanbug-agent' || die "downloaded file does not look like zanbug-agent"
bash -n "$tmp" || die "downloaded agent has a syntax error (bash too old? need bash 4+)"
install -m 0755 "$tmp" "$BIN"; rm -f "$tmp"
ok "installed $BIN ($($BIN version 2>/dev/null || echo '?'))"

# ---- 1b. module auto-detection (no flags on first install, or --auto) --------
running() { pgrep -x "$1" >/dev/null 2>&1 || ps -eo comm= 2>/dev/null | grep -qx "$1"; }
if [ "$AUTO" = "1" ] || { [ ! -f "$CONF" ] && [ -z "$ON" ] && [ -z "$OFF" ]; }; then
    ON="$ON server"
    if running mysqld || running mariadbd || [ -S /var/run/mysqld/mysqld.sock ] || [ -S /run/mysqld/mysqld.sock ]; then
        ON="$ON mysql"; say "auto: MySQL/MariaDB is running here → mysql module ON"
    fi
    if running postgres || running postmaster || ls /var/run/postgresql/.s.PGSQL.* >/dev/null 2>&1; then
        ON="$ON postgres"; say "auto: PostgreSQL is running here → postgres module ON"
    fi
    case "$ON" in *mysql*|*postgres*) ;; *) say "auto: no database engine found on this host — server module only (add later with --mysql / --postgres)";; esac
fi

# ---- 2. config (create or update in place; never lose existing values) ----
mkdir -p "$CONF_DIR" "$STATE_DIR"
if [ ! -f "$CONF" ]; then
    [ -n "$KEY" ] || die "--key <API_KEY> is required on first install (project → Server tab)"
    [ -n "$ON" ] || ON=" server"
    DEF_MYSQL="mysql"; command -v mariadb >/dev/null 2>&1 && DEF_MYSQL="mariadb"   # avoids the "Deprecated program name" noise
    ( umask 077; cat > "$CONF" <<CONF_EOF
# zanbug-agent configuration — written by install.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Re-run the installer with --server / --mysql / --postgres to add modules,
# or edit here and: systemctl restart zanbug-agent
ZANBUG_API_KEY="$KEY"
ZANBUG_HOST="$HOST"
HOST_NAME="$NAME"
MONITOR_SERVER=0
MONITOR_MYSQL=0
MONITOR_PGSQL=0
# admin access to the database engines (only used by the mysql / postgres modules)
MYSQL_CMD="$DEF_MYSQL"
PG_CMD=""
# leave empty to auto-detect from the engine (SHOW VARIABLES / SHOW log_directory)
MYSQL_SLOW_LOG=""
PG_LOG_DIR=""
# on (re)start the agent re-reads this many lines of the slow log so nothing logged while it was down is lost (already-sent entries are skipped)
MYSQL_BACKLOG_LINES=5000
DISK_PATH="/"
DEBUG=0
CONF_EOF
    )
    ok "created $CONF (mode 600)"
else
    ok "keeping existing $CONF"
fi
chmod 600 "$CONF"

setvar() {  # setvar NAME VALUE — replace or append NAME="VALUE" in the conf
    if grep -q "^$1=" "$CONF"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$CONF"
    else
        printf '%s="%s"\n' "$1" "$2" >> "$CONF"
    fi
}
[ -n "$KEY" ] && setvar ZANBUG_API_KEY "$KEY"
[ -n "$NAME" ] && setvar HOST_NAME "$NAME"
[ "$HOST" != "https://zanbug.com" ] && setvar ZANBUG_HOST "$HOST"
[ -n "$MYSQL_CMD_OPT" ] && setvar MYSQL_CMD "$MYSQL_CMD_OPT"
[ -n "$PG_CMD_OPT" ] && setvar PG_CMD "$PG_CMD_OPT"
for m in $ON; do
    case "$m" in server) setvar MONITOR_SERVER 1;; mysql) setvar MONITOR_MYSQL 1;; postgres) setvar MONITOR_PGSQL 1;; esac
    ok "module ON:  $m"
done
for m in $OFF; do
    case "$m" in server) setvar MONITOR_SERVER 0;; mysql) setvar MONITOR_MYSQL 0;; postgres) setvar MONITOR_PGSQL 0;; esac
    ok "module OFF: $m"
done
# numbers must not be quoted for the agent's [ = 1 ] tests — they are compared as strings, quotes are fine.

# ---- 3. database modules: make sure the engine actually logs slow queries ---
. "$CONF"
if [ "${MONITOR_MYSQL:-0}" = "1" ] && [ "$DB_SETUP" = "1" ]; then
    # the service has no HOME (no ~/.my.cnf): when the plain client cannot log in, try the credential files
    # every distro ships — Debian/Ubuntu maintenance account, root's own .my.cnf — and persist the working one.
    if [ -z "$MYSQL_CMD_OPT" ] && ! $MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ 1" >/dev/null 2>&1; then
        base="${MYSQL_CMD%% *}"
        for cf in /etc/mysql/debian.cnf /root/.my.cnf /etc/zanbug/mysql.cnf; do
            [ -r "$cf" ] || continue
            if $base --defaults-file="$cf" --comments -N -B -e "SELECT /* zanbug-agent */ 1" >/dev/null 2>&1; then
                MYSQL_CMD="$base --defaults-file=$cf"; setvar MYSQL_CMD "$MYSQL_CMD"; ok "mysql: using credentials from $cf"; break
            fi
        done
    fi
    if $MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ 1" >/dev/null 2>&1; then
        # the daemon runs without HOME (no ~/.my.cnf) — warn when the user we see lacks PROCESS,
        # otherwise the spike process list and the inventory only show that user's own threads.
        cu="$($MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ CURRENT_USER()" 2>/dev/null)"
        $MYSQL_CMD --comments -N -B -e "SHOW /* zanbug-agent */ GRANTS" 2>/dev/null | grep -qE "ALL PRIVILEGES ON \*\.\*|[ ,]PROCESS[ ,]" \
            || warn "mysql: connected as ${cu:-?} without PROCESS privilege — processlist/inventory will be partial (use --mysql-cmd with an admin user; the service itself does not read ~/.my.cnf)"
        if [ "$($MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ @@slow_query_log" 2>/dev/null)" != "1" ] || [ "$($MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ @@log_output" 2>/dev/null)" != "FILE" ]; then
            say "mysql: slow_query_log is off (or not FILE) — enabling with long_query_time=${SLOW_S}s"
            ZANBUG_AGENT_CONF="$CONF" "$BIN" setup-mysql "$SLOW_S" || warn "could not enable the MySQL slow log automatically; run: zanbug-agent setup-mysql $SLOW_S"
        else
            ok "mysql: slow_query_log already on (long_query_time=$($MYSQL_CMD --comments -N -B -e "SELECT /* zanbug-agent */ @@long_query_time" 2>/dev/null)s)"
        fi
    else
        warn "mysql: cannot connect with MYSQL_CMD='$MYSQL_CMD'. Set it in $CONF (e.g. mysql --defaults-file=/etc/zanbug/mysql.cnf with an admin user) and restart the service."
    fi
fi
if [ "${MONITOR_PGSQL:-0}" = "1" ] && [ "$DB_SETUP" = "1" ]; then
    PGC="${PG_CMD:-}"; [ -z "$PGC" ] && { id postgres >/dev/null 2>&1 && PGC="$(command -v setpriv >/dev/null 2>&1 && echo "setpriv --reuid=postgres --regid=postgres --init-groups psql" || echo "sudo -u postgres psql")" || PGC="psql"; }
    if $PGC -X -q -At -c "SELECT 1" >/dev/null 2>&1; then
        cur="$($PGC -X -q -At -c "SHOW log_min_duration_statement" 2>/dev/null)"
        if [ "$cur" = "-1" ]; then
            say "postgres: log_min_duration_statement is -1 (off) — enabling at ${SLOW_MS}ms"
            ZANBUG_AGENT_CONF="$CONF" "$BIN" setup-postgres "$SLOW_MS" || warn "could not enable PostgreSQL duration logging; run: zanbug-agent setup-postgres $SLOW_MS"
        else
            ok "postgres: log_min_duration_statement already $cur"
        fi
    else
        warn "postgres: cannot connect with PG_CMD='$PGC'. Set PG_CMD in $CONF and restart the service."
    fi
fi

# ---- 4. systemd ----------------------------------------------------------
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Zanbug monitoring agent (server / mysql / postgres modules)
Documentation=$HOST/agent/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run
Restart=always
RestartSec=10
Nice=10
IOSchedulingClass=idle
# the agent only reads /proc, the DB slow logs and talks to $HOST
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable zanbug-agent >/dev/null 2>&1 || true
systemctl restart zanbug-agent
ok "service zanbug-agent enabled + started"

# ---- 5. prove it reaches the panel ---------------------------------------
say "testing connection"
if ZANBUG_AGENT_CONF="$CONF" "$BIN" test; then
    echo
    ok "done — open the project's Server tab in the panel; the first samples arrive within a minute."
    echo "   status:  zanbug-agent status     log: journalctl -u zanbug-agent -f"
    ak="${KEY:-$(sed -n 's/^ZANBUG_API_KEY="\(.*\)"/\1/p' "$CONF" 2>/dev/null | head -n1)}"
    if [ -n "$ak" ]; then iu="$HOST/agent/$ak/install.sh"; else iu="$HOST/agent/install.sh"; fi
    echo "   add module later:  curl -fsSL $iu | sudo bash -s -- --mysql   (or --postgres / --server)"
else
    die "the agent could not reach $HOST — check the key and outbound HTTPS, then: zanbug-agent test"
fi
