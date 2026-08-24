# Zabbix Deployment — 50 Switches + 10 Firewalls

Sizing, configuration, and best-practice setup for monitoring:

- ~50 switches: Cisco Catalyst 2960-X (48 port) and FortiSwitch 448 FPOE
- ~10 firewalls (FortiGate)
- **All ports monitored** on all switches, but **alerts/emails only for trunks/uplinks** plus CPU, memory, fans, PSU, temperature
- Metric history **and** device syslog kept for **1 month**

Platform: Ubuntu Server 24.04 LTS + MySQL 8.x + **Zabbix 7.0 LTS** (the
current recommended production version — 8.0 is still in beta as of Aug 2026;
everything here works identically on both).

**Building a fresh VM? Start with [`INSTALL.md`](INSTALL.md)** — full
step-by-step including how to disable automatic updates so MySQL/Zabbix never
restart without your explicit command. Ongoing care: [`MAINTENANCE.md`](MAINTENANCE.md).

---

## 1. Sizing — what this workload actually is

| Factor | Estimate |
|---|---|
| Monitored interfaces | ~2,500 (50 × 48 ports + uplinks) |
| Items total | ~25,000–28,000 (≈9 items/interface + device health + firewalls) |
| New values per second (NVPS) | ~150–200 |
| Zabbix class | Small-to-medium install — comfortably a single server |

### Recommended server specs

| Resource | Minimum | **Recommended** | Notes |
|---|---|---|---|
| CPU | 2 vCPU | **4 vCPU** | SNMP polling is light in 8.0 (async pollers); headroom for housekeeping spikes |
| RAM | 8 GB | **16 GB** | ~6 GB MySQL buffer pool + ~1.5 GB Zabbix caches + web/OS |
| Disk | 100 GB SSD | **200 GB SSD** | Must be SSD — the database is I/O bound, not CPU bound. See breakdown below |
| Network | 1 GbE | 1 GbE | Polling traffic is trivial (<5 Mbps) |

Run Zabbix server, MySQL, and the web frontend on this one machine — splitting them is unnecessary below ~1,000 NVPS.

### Disk space breakdown (with 1-month history)

| Data | Calculation | Size |
|---|---|---|
| Raw history, 31 days | ~175 NVPS × 86,400 s × 31 d × ~90 bytes/value | **~45 GB** |
| Trends (hourly min/avg/max), 1 year | ~27k items × 24/day × 365 × ~128 bytes | **~30 GB** |
| Events/alerts/audit, 31 days | | ~2 GB |
| Syslog from 60 devices, 31 days (flat files) | | ~2–5 GB |
| OS + software + MySQL redo/temp | | ~30 GB |
| **Total used** | | **~110–120 GB** |

200 GB gives you safe headroom for growth and MySQL maintenance operations.

> **Why keep trends longer than 1 month?** Trends are hourly min/avg/max summaries — they cost ~30 GB/year and give you year-over-year capacity graphs. Your "1 month" requirement applies to raw per-second/minute history and syslog; trends at 365 days is the standard best practice. If you truly want everything gone after a month, set trends to 31d too and save ~28 GB.

---

## 2. Install layout / files in this repo

| File | Goes to | Purpose |
|---|---|---|
| `zabbix_server.conf` | `/etc/zabbix/zabbix_server.conf` | Tuned Zabbix server config (pollers, caches) |
| `mysql/zabbix.cnf` | `/etc/mysql/mysql.conf.d/zabbix.cnf` | MySQL 8 tuning for Zabbix |
| `rsyslog/10-network-syslog.conf` | `/etc/rsyslog.d/10-network-syslog.conf` | Receives syslog from switches/firewalls into per-device files |
| `logrotate/network-syslog` | `/etc/logrotate.d/network-syslog` | Enforces 31-day syslog retention |
| `TEMPLATES.md` | (documentation) | Which templates to use and how to alert only on trunks |

Apply and restart:

```bash
sudo cp zabbix_server.conf /etc/zabbix/zabbix_server.conf
sudo cp mysql/zabbix.cnf /etc/mysql/mysql.conf.d/zabbix.cnf
sudo cp rsyslog/10-network-syslog.conf /etc/rsyslog.d/10-network-syslog.conf
sudo cp logrotate/network-syslog /etc/logrotate.d/network-syslog
sudo mkdir -p /var/log/network
sudo chown syslog:adm /var/log/network

sudo systemctl restart mysql
sudo systemctl restart zabbix-server
sudo systemctl restart rsyslog
```

Check it came up clean:

```bash
sudo tail -50 /var/log/zabbix/zabbix_server.log
```

---

## 3. Database setup

### 3.1 Character set (do this once, before adding hosts)

Zabbix 8.0 requires `utf8mb4`. If your basic install created the DB as `utf8mb3`/`utf8`, convert it. Check:

```sql
SELECT default_character_set_name FROM information_schema.SCHEMATA
WHERE schema_name = 'zabbix';
```

If it says `utf8mb4` you are done. If not, follow the official conversion:
https://www.zabbix.com/documentation/8.0/en/manual/appendix/install/db_charset_coll

Correct creation statement for reference:

```sql
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'STRONG_PASSWORD_HERE';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;  -- only during schema import
```

### 3.2 MySQL tuning

Everything is in `mysql/zabbix.cnf` (commented). The three settings that matter most:

- `innodb_buffer_pool_size = 6G` — the single most important knob. Rule of thumb: ~40% of RAM when Zabbix shares the box.
- `innodb_flush_log_at_trx_commit = 2` — huge write-load reduction; worst case you lose ~1 s of monitoring data on a power cut, which is irrelevant for metrics.
- `disable-log-bin` — you don't run replication; binary logs would double your write I/O and eat disk.

### 3.3 Partitioning (optional, skip for now)

At your size, the built-in housekeeper handles 1-month retention fine. If you ever grow past ~1,000 NVPS, look at table partitioning for `history*`/`trends*` tables. Not needed today — keeping it simple is the right call for a first deployment.

---

## 4. Zabbix caches — what's set and why

Set in `zabbix_server.conf` (already done in the file in this repo):

| Parameter | Value | Why |
|---|---|---|
| `CacheSize` | 256M | Configuration cache — hosts/items/triggers. 28k items fits with big headroom |
| `HistoryCacheSize` | 256M | Buffer for collected values before DB write |
| `HistoryIndexCacheSize` | 64M | Index for the history cache |
| `TrendCacheSize` | 128M | Hourly trend aggregation buffer |
| `ValueCacheSize` | 512M | Keeps recent values in RAM so trigger evaluation never hits the DB — biggest UI/trigger speed win |
| `StartSNMPPollers` | 8 | Zabbix 8 async SNMP pollers; each handles up to 1,000 concurrent checks — 8 is generous for 60 devices |
| `StartDBSyncers` | 4 | History write throughput |
| `HousekeepingFrequency` | 1 | Delete expired data every hour in small chunks instead of huge nightly spikes |

After a week of running, check *Reports → System information* — all cache "% used" values should be well under 80%. `zabbix[wcache,*]` and `zabbix[rcache,*]` internal items are already collected by the "Zabbix server health" template; keep it on the server host.

---

## 5. 1-month retention — the actual settings

Retention lives in **three** places. All three are covered here:

### 5.1 Metric history (web UI — this is the main one)

*Administration → Housekeeping:*

- **History** — ✔ Enable internal housekeeping, ✔ **Override item history period** = `31d`
- **Trends** — ✔ Enable internal housekeeping, ✔ Override item trend period = `365d` (or `31d` if you want strict 1-month everything)
- **Events and alerts** — `31d` for all event types
- **User sessions** — `31d`
- **Audit** — `31d`

The "Override" checkboxes are important: they force 31 days globally regardless of what any template sets per-item, so you never have to audit thousands of items.

### 5.2 Syslog files (rsyslog + logrotate)

Switches/firewalls send syslog to the Zabbix server on UDP 514; rsyslog writes one file per device under `/var/log/network/`, and logrotate deletes anything older than 31 days. See `rsyslog/10-network-syslog.conf` and `logrotate/network-syslog`.

On each Cisco switch:

```
logging host <zabbix-server-ip>
logging trap informational
```

On each FortiGate/FortiSwitch:

```
config log syslogd setting
    set status enable
    set server "<zabbix-server-ip>"
    set port 514
end
```

**Best practice:** keep syslog in flat files (cheap, greppable), and let Zabbix *alert* on patterns in them if needed via a log item — do not stuff full syslog streams into the database. If you later want specific syslog lines searchable in Zabbix, add a `log[/var/log/network/...,pattern]` item; its history is automatically capped at 31 days by the override in 5.1.

### 5.3 SNMP traps (optional but recommended)

For instant link-down notification on trunks (instead of waiting for the next poll), configure `snmptrapd` + the Zabbix trap file (`SNMPTrapperFile` is already enabled in the server config). Docs: https://www.zabbix.com/documentation/8.0/en/manual/config/items/itemtypes/snmptrap

---

## 6. Adding the devices

Use **SNMPv3** if your gear is configured for it (authPriv, SHA/AES); otherwise SNMPv2c with a non-default community. Create the hosts via *Data collection → Hosts → Create host*, interface type SNMP, and attach the templates described in `TEMPLATES.md`.

For 50 switches, don't click them in one by one — use *Data collection → Discovery* (network discovery on your management subnet) with a discovery action that auto-adds hosts and links the right template based on SNMP `sysDescr`, or import a CSV via the API later. For a first pass, adding the 4–5 distinct device types manually and cloning is also fine.

---

## 7. Quick health checklist after go-live

- [ ] *Reports → System information*: NVPS shown (~150–200 expected), all caches < 80%
- [ ] `Zabbix server health` template linked to the Zabbix server host — gives you queue, cache, and process-busy graphs
- [ ] Queue (*Administration → Queue*) near zero — a growing queue means pollers or the DB can't keep up
- [ ] Disk usage trend on `/var/lib/mysql` flat after ~35 days (housekeeper is deleting as fast as data arrives)
- [ ] Test an alert: `shutdown` a lab trunk port → email arrives; `shutdown` an access port → **no** email
