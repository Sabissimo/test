# Manual Updates & Upkeep

Because automatic updates are disabled (INSTALL.md §8), **you** are the update
mechanism. This is the routine. Rule of thumb for time: ~15 min/month for OS
patching, ~30 min/quarter for Zabbix/MySQL, and the weekly check is 2 minutes.

## 1. Golden rules

1. **Snapshot the VM before any update.** It turns every mistake into a
   5-minute rollback. Delete the snapshot after a few days of stable running
   (long-lived snapshots hurt VM disk performance).
2. Update during a maintenance window; set one in Zabbix too
   (*Data collection → Maintenance*) so you don't alert on yourself.
3. One layer at a time: OS first, verify. Zabbix another day. MySQL another
   day. If something breaks you know what caused it.
4. Never `apt full-upgrade` or `dist-upgrade` on this box, and never
   `do-release-upgrade` (Ubuntu version jump) without a tested plan.

## 2. Monthly: OS security patching (~15 min)

The package holds keep MySQL/Zabbix untouched, so this is safe for them:

```bash
sudo apt update
apt list --upgradable        # review what's coming; held pkgs won't appear
sudo apt upgrade             # respects holds automatically
```

Reboot only if required:

```bash
[ -f /var/run/reboot-required ] && echo "REBOOT NEEDED" || echo "no reboot needed"
# if needed, during the maintenance window:
sudo reboot
```

After reboot: web UI loads, *Reports → System information* shows
"Zabbix server is running: yes".

## 3. Quarterly (or on a fix you need): Zabbix minor update (7.0.x → 7.0.y)

Minor releases are bugfix-only, no schema surprises, downtime ~1 minute.

```bash
# 0) VM snapshot + config backup (see §5)

# 1) Release the holds temporarily
sudo apt-mark unhold 'zabbix-server-mysql' 'zabbix-frontend-php' \
  'zabbix-apache-conf' 'zabbix-sql-scripts' 'zabbix-agent2'

# 2) Update ONLY the zabbix packages
sudo apt update
sudo apt install --only-upgrade 'zabbix-server-mysql' 'zabbix-frontend-php' \
  'zabbix-apache-conf' 'zabbix-sql-scripts' 'zabbix-agent2'
# If apt asks about zabbix_server.conf: keep YOUR version (option N /
# "keep the local version currently installed") — your tuning lives there.

# 3) Restart and verify
sudo systemctl restart zabbix-server zabbix-agent2 apache2
sudo tail -30 /var/log/zabbix/zabbix_server.log     # no errors, "started"
zabbix_server -V                                     # new version

# 4) Re-arm the holds — do not skip this
sudo apt-mark hold 'zabbix-server-mysql' 'zabbix-frontend-php' \
  'zabbix-apache-conf' 'zabbix-sql-scripts' 'zabbix-agent2'
apt-mark showhold
```

## 4. Semi-annually: MySQL minor update (8.0.x → 8.0.y)

Downtime ~1–2 minutes (Zabbix server buffers/retries during it, the web UI is
briefly unavailable — that's expected and fine when *you* choose the moment).

```bash
# 0) VM snapshot + DB backup (see §5)

sudo apt-mark unhold 'mysql-server*' 'mysql-client*' mysql-common
sudo apt update
sudo apt install --only-upgrade 'mysql-server*' 'mysql-client*' mysql-common

sudo systemctl restart mysql
sudo systemctl restart zabbix-server          # reconnects immediately
sudo tail -20 /var/log/mysql/error.log
mysql -V

sudo apt-mark hold 'mysql-server*' 'mysql-client*' mysql-common
apt-mark showhold
```

## 5. Backups

Two layers, both cheap:

**Nightly config-only DB dump** — everything that took you effort (hosts,
templates, triggers, users, maps) *without* the bulky history/trends data.
It's a few hundred MB instead of ~100 GB:

```bash
sudo tee /usr/local/sbin/zabbix-backup.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
DEST=/var/backups/zabbix
mkdir -p "$DEST"
IGNORE=""
for t in history history_uint history_str history_log history_text history_bin \
         trends trends_uint auditlog events event_recovery event_suppress \
         event_tag event_symptom problem problem_tag alerts acknowledges; do
  IGNORE="$IGNORE --ignore-table=zabbix.$t"
done
# Data of everything except bulk tables:
mysqldump --single-transaction --no-tablespaces $IGNORE zabbix | gzip \
  > "$DEST/zabbix-config-$(date +%F).sql.gz"
# Schema (structure only) of ALL tables, so a restore can recreate the bulk ones empty:
mysqldump --no-data --no-tablespaces zabbix | gzip \
  > "$DEST/zabbix-schema-$(date +%F).sql.gz"
# Config files:
tar czf "$DEST/zabbix-etc-$(date +%F).tar.gz" \
  /etc/zabbix /etc/mysql/mysql.conf.d /etc/rsyslog.d /etc/logrotate.d/network-syslog 2>/dev/null
# Keep 14 days:
find "$DEST" -type f -mtime +14 -delete
EOF
sudo chmod 700 /usr/local/sbin/zabbix-backup.sh
```

Give the script DB access via a root client config, then schedule it:

```bash
sudo tee /root/.my.cnf >/dev/null <<'EOF'
[client]
user=zabbix
password=YOUR_DB_PASSWORD
EOF
sudo chmod 600 /root/.my.cnf

( sudo crontab -l 2>/dev/null; echo "30 2 * * * /usr/local/sbin/zabbix-backup.sh" ) | sudo crontab -
```

**Weekly VM-level snapshot/backup** via your hypervisor's backup tool (Veeam,
Proxmox Backup, etc.) — this is the one that also covers history data.

**Restore drill (know it before you need it):** create empty DB as in
INSTALL.md step 4 → `zcat schema.gz | mysql zabbix` → `zcat config.gz | mysql zabbix`
→ untar `/etc` files → start services. History is gone (or comes from the VM
backup), config is complete.

## 6. Weekly 2-minute health check

- *Reports → System information*: server running **yes**, NVPS in the
  expected ~150–250 range, every cache below 80% used
- *Administration → Queue*: values at "5 seconds"/"10 seconds" ≈ everything,
  nothing piling up in "more than 10 minutes"
- `df -h /` and `/var/lib/mysql` — after day ~35 the DB size should be
  **flat** month over month (housekeeper deleting as fast as data arrives);
  steady growth means retention overrides aren't set (README §5.1)
- `ls /var/log/network/ | head` — syslog files exist and rotate
  (nothing older than ~31 days: `find /var/log/network -mtime +32`)

Better: let Zabbix watch itself — the **Zabbix server health** and **Linux by
Zabbix agent** templates on the Zabbix host alert on cache exhaustion, queue
growth, low disk, and service down, so the weekly check becomes glancing at
one dashboard.

## 7. The big one later: upgrading to Zabbix 8.0 LTS when it's GA

Don't do this while 8.0 is beta. When it's stable (check
https://www.zabbix.com/download shows 8.0 as a release, not pre-release, and
ideally wait for 8.0.2+):

1. VM snapshot + full backup. Read the 8.0 upgrade notes:
   https://www.zabbix.com/documentation/8.0/en/manual/installation/upgrade_notes_800
2. Swap the repo: install the 8.0 `zabbix-release` package for Ubuntu 24.04
   (same pattern as INSTALL.md step 3, `7.0` → `8.0`)
3. Unhold zabbix packages, `sudo apt update && sudo apt install --only-upgrade 'zabbix-*'`
4. `sudo systemctl restart zabbix-server` — on first start it migrates the
   DB schema automatically. **Do not interrupt it**; watch progress in
   `/var/log/zabbix/zabbix_server.log`. With ~100 GB of history this can
   take a while — plan an evening window.
5. Restart apache2, clear browser cache, verify, re-hold packages.

Ubuntu 24.04 LTS itself is supported to 2029 — no OS upgrade needed in this
hardware's lifetime.
