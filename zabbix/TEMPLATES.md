# Templates & Alerting: Cisco 2960-X, FortiSwitch, FortiGate

Goal: **collect data on every port**, but **fire alerts (and emails) only for trunk/uplink ports** plus device health (CPU, memory, temperature, fans, PSU).

## 1. Which templates to use

All ship with Zabbix 8.0 (*Data collection → Templates*, search by name). Attach via the host's **Templates** field.

| Device | Template | Notes |
|---|---|---|
| Cisco Catalyst 2960-X | **Cisco IOS by SNMP** | Official. Discovers all interfaces; monitors CPU, memory, temperature, fans, PSU via CISCO-* MIBs |
| FortiGate firewalls | **FortiGate by SNMP** | Official. CPU, memory, sessions, interfaces, HA, VPN tunnels |
| FortiSwitch 448 FPOE | No official template — see below | |
| Zabbix server itself | **Zabbix server health** + **Linux by Zabbix agent** | Self-monitoring: caches, queue, disk, MySQL |

**FortiSwitch options**, best first:

1. If the FortiSwitches are managed by your FortiGates (FortiLink), the **FortiGate by SNMP** template on the FortiGate already reports managed-switch status; combine with option 2 for per-port data.
2. Import a community FortiSwitch template from the official community repo: https://github.com/zabbix/community-templates (search "FortiSwitch") — covers CPU/memory/PSU via FORTINET-FORTISWITCH-MIB.
3. Minimum fallback: attach the generic **Network Generic Device by SNMP** template — FortiSwitch fully supports the standard IF-MIB, so all per-port traffic/error/status data works out of the box; you lose only vendor-specific health items.

## 2. Alert only on trunks — the `{$IFCONTROL}` pattern

The official network templates gate every interface's "Link down" trigger behind the macro `{$IFCONTROL}` (1 = alert, 0 = collect data but stay silent). Macros support **context with regex**, so you can flip alerting per interface name in two lines. Set these under *host → Macros* (or on a template you clone, to apply everywhere):

### Cisco 2960-X

Access ports on a 48-port 2960-X are `Gi1/0/1–48`; uplinks are the SFP/SFP+ module ports (`Gi1/0/49–52` on -TS models, `Te1/0/1–2` on -PD/-FPD models) and any port-channels (`Po1`…).

| Macro | Value | Effect |
|---|---|---|
| `{$IFCONTROL}` | `0` | Default: no link-down alerts on any port |
| `{$IFCONTROL:regex:"^(Te|Po|Gi[0-9]+\/0\/(49|5[0-2]))"}` | `1` | Alerts ON for TenGig uplinks, port-channels, and Gi x/0/49–52 |

Adjust the regex to your actual uplink layout (`show interfaces status` on the switch shows the names Zabbix will discover). In a stack, uplinks exist per member: `Gi2/0/49` etc. — the regex above already matches any stack member number.

### FortiSwitch / FortiGate

Same mechanism, Fortinet port naming:

| Macro | Value | Effect |
|---|---|---|
| `{$IFCONTROL}` | `0` | Silence all ports by default |
| `{$IFCONTROL:regex:"^(port(4[5-8])|.*[Tt]runk|.*uplink|fortilink)"}` | `1` | Example: alert on ports 45–48 (SFP+ uplinks on the 448), trunk aggregates, FortiLink |

On FortiGates you likely want the inverse — alert on **all** interfaces (`{$IFCONTROL}=1`, the default) since every firewall port matters.

### Interface bandwidth/error triggers

The same templates also alert on high utilization ("Interface … high bandwidth usage") and error rates. To restrict those to trunks as well, use their context macros the same way:

| Macro | Default | Trunk-only pattern |
|---|---|---|
| `{$IF.UTIL.MAX}` | `90` (%) | `{$IF.UTIL.MAX}` = `101` (never fires), `{$IF.UTIL.MAX:regex:"^(Te|Po|Gi[0-9]+\/0\/(49|5[0-2]))"}` = `90` |
| `{$IF.ERRORS.WARN}` | `2` (errors/s) | same context-regex approach |

Device-health triggers (CPU util, memory, temperature, fan/PSU state) have no interface context — they fire per device out of the box, which is exactly what you want. Their thresholds are tunable via `{$CPU.UTIL.CRIT}`, `{$MEMORY.UTIL.MAX}`, `{$TEMP_CRIT}` etc. if the defaults (90/90/60 °C) don't suit.

## 3. Polling intervals — keep the footprint sane

Template defaults are reasonable, but with 2,400 access ports one tweak pays off. On the host/template macros:

| Macro | Suggested | Meaning |
|---|---|---|
| `{$NET.IF.UPDATE.INTERVAL}` (if present) or item-level | `3m`–`5m` | Traffic/error counters. 1m on 2,400 ports is pointless load |
| Interface **discovery** interval | `1h` | How fast a newly-configured port appears in Zabbix |
| Device health (CPU/mem/temp) | `1m`–`2m` | Keep responsive — it's only ~30 items per device |

Also set on each interface-discovery rule (already the template default in 8.0): *Keep lost resources period* = `7d`, so unplugged ports age out instead of accumulating forever.

## 4. Email notifications

1. *Alerts → Media types → Email*: fill in your SMTP server, port 587 + STARTTLS, auth user. **Test** button to verify.
2. *Users → your user → Media*: add Email with your address, severity filter (e.g., only **Warning and above**), active 24×7.
3. *Alerts → Actions → Trigger actions*: enable the built-in "Report problems to Zabbix administrators" action, or create one:
   - Condition: severity ≥ Warning
   - Operations: send to user group "Zabbix administrators", all media
   - ✔ *Recovery operations* → notify — so you get "Resolved" mails too.

Because alert scoping is done with `{$IFCONTROL}` at the trigger level (access-port triggers never fire at all), the action needs no complicated conditions — anything that fires is worth an email.

## 5. Best practices checklist

- **SNMPv3** (authPriv, SHA1/AES128 minimum) on all devices if supported; otherwise SNMPv2c with a unique, non-default community, and restrict SNMP by ACL on each device to the Zabbix server IP.
- On the 2960-X: `snmp-server community <ro-community> RO <acl>`, and enable `snmp-server enable traps snmp linkdown linkup` + `snmp-server host <zabbix-ip>` for instant trunk-down traps.
- Group hosts (*Host groups*): `Switches/Cisco`, `Switches/FortiSwitch`, `Firewalls` — makes actions, permissions, and maintenance windows clean.
- Use **maintenance windows** (*Data collection → Maintenance*) before planned changes so you don't get 50 emails during a firmware upgrade night.
- Clone official templates before customizing (name them `Cisco IOS by SNMP - <yourorg>`), so Zabbix upgrades don't overwrite your macro changes.
- Add a **dashboard**: top-N trunk utilization graph, problems widget filtered to `Warning+`, and a host-availability map. The 8.0 default dashboard widgets cover all three.
