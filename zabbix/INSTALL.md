# Fresh Install: Zabbix 7.0 LTS on Ubuntu Server 24.04 LTS

Step-by-step build of a new VM, from blank OS to working web UI, using the
tuned configs in this repo. Every command is copy-paste ready.

> **Why 7.0 and not 8.0?** As of August 2026, Zabbix 8.0 is still in **beta**
> (GA slipped past its planned Q2 2026 date). Betas live in Zabbix's
> *unstable* repo and are not for production. **Zabbix 7.0 LTS** is the
> current recommended production version, supported until 2029. When 8.0 GA
> ships, the upgrade path from 7.0 is a standard supported upgrade (see
> MAINTENANCE.md §6). Everything in this repo (server config, MySQL config,
> templates, macros) works identically on 7.0.

## VM to create

| Setting | Value |
|---|---|
| vCPU | 4 |
| RAM | 16 GB |
| Disk | 200 GB, **thin-provisioned on SSD storage** |
| OS | Ubuntu Server 24.04.x LTS (minimal install, OpenSSH server only) |
| Network | Static IP on the management VLAN (reachable by all switches/firewalls) |

During the Ubuntu installer: do **NOT** tick "Install security updates
automatically" if offered, and skip all snaps. We control updates manually
(step 8).

---

## Step 1 — Base OS prep

Log in via SSH, then:

```bash
# Bring the fresh OS fully up to date ONCE, before we lock things down
sudo apt update && sudo apt -y upgrade
sudo reboot
```

After reboot:

```bash
# Set timezone (adjust to yours)
sudo timedatectl set-timezone Europe/Berlin

# Reliable time is critical for monitoring — verify NTP is active
timedatectl   # expect "System clock synchronized: yes"

# Basic firewall: SSH, web UI, syslog, SNMP traps
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 514/udp
sudo ufw allow 514/tcp
sudo ufw allow 162/udp
sudo ufw enable
```

## Step 2 — Install MySQL 8

```bash
sudo apt install -y mysql-server
sudo systemctl enable mysql
```

Secure it (sets root policy, removes test accounts — answer Y to the removal
questions, pick a strong root password):

```bash
sudo mysql_secure_installation
```

## Step 3 — Add the Zabbix 7.0 LTS repository and install packages

```bash
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
sudo dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb
sudo apt update

sudo apt install -y zabbix-server-mysql zabbix-frontend-php \
  zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 \
  snmp snmp-mibs-downloader fping
```

(If that exact `.deb` filename 404s, get the current one from
https://www.zabbix.com/download → Ubuntu 24.04 → 7.0 LTS.)

`snmp-mibs-downloader` needs the `multiverse` repo; if it fails:
`sudo add-apt-repository multiverse && sudo apt update` and retry.

## Step 4 — Create the database (utf8mb4 from day one)

```bash
sudo mysql
```

```sql
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'PUT_A_STRONG_PASSWORD_HERE';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
QUIT;
```

Import the initial schema (takes a few minutes, silent while running):

```bash
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | \
  mysql --default-character-set=utf8mb4 -uzabbix -p zabbix
```

Then turn the import-only setting back off:

```bash
sudo mysql -e "SET GLOBAL log_bin_trust_function_creators = 0;"
```

## Step 5 — Apply the tuned configs from this repo

```bash
git clone <this-repo-url> && cd <repo>/zabbix

sudo cp zabbix_server.conf /etc/zabbix/zabbix_server.conf
sudo nano /etc/zabbix/zabbix_server.conf   # set DBPassword= to the password from step 4

sudo cp mysql/zabbix.cnf /etc/mysql/mysql.conf.d/zabbix.cnf

# Syslog receiving + 31-day rotation
sudo cp rsyslog/10-network-syslog.conf /etc/rsyslog.d/
sudo cp logrotate/network-syslog /etc/logrotate.d/
sudo mkdir -p /var/log/network /var/log/snmptrap
sudo chown syslog:adm /var/log/network
```

Set the PHP timezone for the frontend:

```bash
sudo sed -i 's|^;*\s*php_value\[date.timezone\].*|php_value[date.timezone] = Europe/Berlin|' \
  /etc/zabbix/apache.conf 2>/dev/null || true
sudo sed -i 's|^;\s*php_value date.timezone.*|php_value date.timezone Europe/Berlin|' \
  /etc/apache2/conf-enabled/zabbix.conf
```

## Step 6 — Start everything and enable at boot

```bash
sudo systemctl restart mysql
sudo systemctl restart zabbix-server zabbix-agent2 apache2 rsyslog
sudo systemctl enable  zabbix-server zabbix-agent2 apache2 mysql
```

Verify the server came up clean (no repeated errors):

```bash
sudo tail -50 /var/log/zabbix/zabbix_server.log
```

You should see `server #0 started [main process]` and pollers starting.

## Step 7 — Web frontend setup

Browse to `http://<server-ip>/zabbix`:

1. Welcome → choose language → **Next**
2. Pre-requisites: all green (the PHP packages came with `zabbix-frontend-php`)
3. DB connection: type MySQL, host `localhost`, database `zabbix`, user
   `zabbix`, the password from step 4
4. Server name: something like `zabbix-prod`
5. Finish → log in with **Admin / zabbix** → immediately change that password
   (*User settings → Profile → Change password*)

Then do the retention settings from `README.md` §5.1
(*Administration → Housekeeping* → 31d overrides) and add devices per
`TEMPLATES.md`.

## Step 8 — Lock out automatic updates (the fix for your DB-went-down issue)

Ubuntu 24.04 ships with **unattended-upgrades** enabled: it silently installs
security updates daily, and when the update touches `mysql-server` it
**restarts MySQL**, killing the frontend/DB connection — exactly what you hit
in testing. Two layers of protection:

### 8a. Hold the critical packages (blocks ALL upgrade paths, manual apt included)

```bash
sudo apt-mark hold 'mysql-server*' 'mysql-client*' mysql-common \
  'zabbix-server-mysql' 'zabbix-frontend-php' 'zabbix-apache-conf' \
  'zabbix-sql-scripts' 'zabbix-agent2' 'zabbix-release'

apt-mark showhold   # verify the list
```

Held packages are skipped by unattended-upgrades **and** by a plain
`sudo apt upgrade`, so nothing can bump or restart MySQL/Zabbix until you
explicitly unhold them (MAINTENANCE.md §3).

### 8b. Turn off unattended-upgrades entirely (nothing installs itself, ever)

```bash
sudo systemctl disable --now unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
EOF
```

> **Trade-off, stated honestly:** with 8b you get *zero* automatic security
> patches — you own patching now, so actually do the monthly routine in
> MAINTENANCE.md §2. If you'd rather keep automatic OS security patches and
> only protect MySQL/Zabbix, skip 8b (keep the service enabled) — the holds
> from 8a alone are enough to keep them untouched. For an internal-only
> monitoring VM behind a firewall, 8a + 8b with disciplined monthly patching
> is a reasonable choice.

### 8c. Never reboot on its own

Automatic reboots are already off with unattended-upgrades disabled; also
confirm no other tooling (VM host policies, Landscape/Canonical Pro) is set
to patch or reboot the VM.

### 8d. Self-heal on crashes (down only by explicit command)

Preventing updates stops *planned* restarts. To also survive *unplanned*
crashes (OOM, bug), tell systemd to restart the services automatically —
`systemctl stop` by you still works normally and is never overridden:

```bash
sudo systemctl edit mysql
```

Add between the comment markers:

```ini
[Service]
Restart=on-failure
RestartSec=5s
```

Repeat for `zabbix-server`:

```bash
sudo systemctl edit zabbix-server
```

```ini
[Service]
Restart=on-failure
RestartSec=5s
```

Apply: `sudo systemctl daemon-reload`

## Step 9 — Final verification

```bash
systemctl is-enabled mysql zabbix-server apache2      # all "enabled"
systemctl is-active  mysql zabbix-server apache2      # all "active"
apt-mark showhold                                     # mysql* + zabbix* listed
sudo systemctl status unattended-upgrades             # "disabled; inactive" (if you did 8b)
sudo reboot                                           # one test reboot...
# ...then confirm the web UI is reachable again with no manual intervention
```

Migration note: since the old test VM is being replaced, either re-add hosts
fresh on this box (cleanest, you know the setup now), or export from the old
one (*Data collection → Hosts → select → Export*) and import here — host
exports carry templates/macros, but not history data.
