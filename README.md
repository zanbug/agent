<p align="center"><img src="https://zanbug.com/logo.png" alt="Zanbug" width="120"></p>

# zanbug-agent

Server & database monitoring agent for [Zanbug](https://zanbug.com). One plain
bash script (`zanbug-agent.sh`), no compiler, no runtime — needs only **root, bash,
curl and systemd**. Runs as `zanbug-agent.service` on the box where your app or
your database lives and pushes to `POST /api/ingest/agent` with the project's
`X-Zanbug-Key`.

## Three independent modules — install only what you need

Every project has its **own** installer URL. Open the project → **Server** tab and copy the
command from the card you need; the downloaded script already contains the project key and host.

| Module | Flag | What it does | Where it shows up |
|---|---|---|---|
| **Server** | `--server` | load / CPU / iowait / RAM / swap / disk / disk IO / network every 5 s; on a threshold breach the sample is pushed **immediately with the top processes** ("what was running when load hit 9"); heartbeat + daily inventory (cron, systemd services & timers, listening ports, PHP/Node versions) | Server tab: charts, spikes, inventory |
| **MySQL / MariaDB** | `--mysql` | tails the engine's **own slow query log** (catches terminal, phpMyAdmin and other apps too, not only what the SDK sees) with `user@host`; `SHOW PROCESSLIST` on spikes; inventory: triggers, routines, events, biggest tables, slow-log settings | Performance tab, source **`mysql-log`** 🐬 · Server tab spike detail |
| **PostgreSQL** | `--postgres` | tails `log_min_duration_statement` lines from the server log; `pg_stat_activity` on spikes; inventory: triggers, functions, tables, extensions, settings | Performance tab, source **`pgsql-log`** 🐘 · Server tab spike detail |

```bash
# Everything in one go (recommended): server module + MySQL/MariaDB and/or PostgreSQL if that engine
# runs on this host — detected automatically, slow log switched on and persisted, service started.
curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash

# Server metrics only
curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --server

# Add MySQL later (re-run is safe: key and other modules are kept, flags accumulate)
curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --mysql

# PostgreSQL
curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --postgres

# Any combination in one go
curl -fsSL https://zanbug.com/agent/<API_KEY>/install.sh | sudo bash -s -- --server --mysql --postgres
```

Generic installer (no baked key, e.g. self-hosted panel):

```bash
curl -fsSL https://zanbug.com/agent/install.sh | sudo bash -s -- --key <API_KEY> --host https://your-panel.example --server
```

`--auto` (implied when no module flag is given on the first install) looks for a running `mysqld`/`mariadbd`
or `postgres` process (or its socket). When the plain `mysql` client cannot log in as root, the installer tries
`/etc/mysql/debian.cnf`, `/root/.my.cnf` and `/etc/zanbug/mysql.cnf` in turn and persists the one that works, so
MySQL 5.7/8, MariaDB and Percona on Debian/Ubuntu/RHEL all install with the same single command.

### Installer options

```
--key KEY                 project API key (required on first install; baked URL supplies it)
--host URL                Zanbug host (default https://zanbug.com)
--server|--mysql|--postgres        switch modules ON (cumulative across runs)
--no-server|--no-mysql|--no-postgres  switch a module OFF
--mysql-cmd 'CMD'         admin MySQL client (default: mysql — socket auth as root)
--pg-cmd 'CMD'            superuser psql (default: sudo -u postgres psql)
--slow-seconds N          MySQL long_query_time to enable when the slow log is off (default 1)
--slow-ms N               PostgreSQL log_min_duration_statement when off (default 1000)
--no-db-setup             never touch database settings, only tail what is already logged
--hostname NAME           name shown in the panel (default: short hostname)
--uninstall               stop + disable service, remove binary (keeps /etc/zanbug/agent.conf);
                          also removes a leftover pre-rename agent service/binary
-h | --help
```

### Upgrading from a pre-rename install (≤ 1.3.1)

Run the same install command. The installer detects the old install and migrates it in place:
the old service is stopped and removed, the old conf moves to `/etc/zanbug/agent.conf` with its
keys renamed to `ZANBUG_API_KEY`/`ZANBUG_HOST`, the state dir (slow-log position — nothing is re-sent)
and the log move, the MySQL slow-log drop-in is renamed, crontab lines calling the old `exec` wrapper
are rewritten to `zanbug-agent exec`, and the old binary is deleted. An un-migrated box still works:
the new agent reads the old conf, state dir and old env keys as a fallback.

## Files

| Path | Purpose |
|---|---|
| `/usr/local/bin/zanbug-agent` | the agent |
| `/etc/zanbug/agent.conf` | config (chmod 600, contains the API key) |
| `/etc/systemd/system/zanbug-agent.service` | unit (`Restart=always`) |
| `/var/lib/zanbug-agent/` | state: slow-log offsets, last inventory, cooldowns |
| `/var/log/zanbug-agent.log` | agent log (also `journalctl -u zanbug-agent`) |

## Commands

```bash
sudo zanbug-agent test            # one full check: config, API reachability, DB connections, log paths
sudo zanbug-agent status          # service state, modules, slow-log settings, last push
sudo zanbug-agent once [reason]   # push one sample + top processes right now (shows as a spike)
sudo zanbug-agent inventory [--send]
sudo zanbug-agent setup-mysql [seconds]     # enable MySQL slow log (default 1 s)
sudo zanbug-agent setup-postgres [ms]       # enable PG duration logging (default 1000 ms)
sudo zanbug-agent backfill [slow-log file]  # push an existing MySQL slow log once (default: the live one; entries older than 7 days are skipped, duplicates are dropped server-side)
sudo zanbug-agent redis [--send]      # one Redis snapshot (INFO, slowlog, big keys)
sudo zanbug-agent exec [--name N] -- CMD ARGS   # run a shell job and report it to the Processes tab
sudo zanbug-agent version
journalctl -u zanbug-agent -f
```

### Shell cron jobs in the Processes tab

Wrap any crontab command with `exec`; it runs unchanged (stdout, stdin and the exit code are
untouched) and one row lands in the project's Processes tab when it finishes (`source=cron`,
`runtime=shell`, duration, CPU/peak memory when GNU time is installed, the last stderr lines on failure):

```cron
0 */4 * * * /usr/local/bin/zanbug-agent exec -- /var/www/backups/mysql.sh
30 2 * * *  /usr/local/bin/zanbug-agent exec --name nightly-cleanup -- /opt/app/cleanup.sh --all
```

## Tuning from the panel

Thresholds and intervals are **not** in the config file: the API returns them in every
response (`Server tab → Settings`): sample interval 2–300 s, heartbeat 15–900 s, top-N
processes 3–25, spike cooldown 10–3600 s, inventory 5 min–7 d, thresholds load/CPU
0.5–20, CPU/RAM/disk % 50–100, iowait % 10–100. A running agent picks changes up on its
next push — no redeploy.

## Notes

* Node and PHP are both covered: the agent is process-agnostic; the SDK's `command_runs`
  and slow queries are correlated with a spike by time (±60 s) in the Server tab.
* The agent never sends query row contents — only the statement text, duration, user@db
  and the time, the same rule as the SDK.
* Uninstall keeps `/etc/zanbug/agent.conf` so a later re-install needs no key; delete
  it manually (`rm -rf /etc/zanbug`) if you want a clean box.
* The service runs without `HOME`, so it does **not** read `~/.my.cnf`; it connects with
  `mysql`/`mariadb` over the socket as the OS root user. If that user lacks `PROCESS`,
  pass an admin login with `--mysql-cmd 'mysql --defaults-file=/etc/zanbug/mysql.cnf'`
  (mode 600) — the installer warns when the privilege is missing.
* PostgreSQL is queried as the `postgres` OS user via `setpriv` (falls back to `sudo -u`),
  and slow-log timestamps are converted from the server's `log_timezone` to UTC.
* Slow-log rows carry `user@db on <hostname>` as their command, so several servers pushing
  into one project stay distinguishable in the Performance tab.
