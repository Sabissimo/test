# DHCP Scope Deployment Wizard (`New-DhcpScopeWizard.ps1`)

Interactive, menu-driven PowerShell tool for deploying and reviewing DHCPv4
scopes on Windows Server. Compatible with **Windows PowerShell 5.x and
PowerShell ISE**.

## Requirements

- Windows Server with the DHCP role, or a management workstation with the
  RSAT DHCP tools (`Install-WindowsFeature RSAT-DHCP`), providing the
  `DhcpServer` PowerShell module.
- An **elevated** (Run as Administrator) PowerShell or ISE session to make
  changes. Viewing/exporting works with DHCP read permissions.

## Usage

Open the script in PowerShell ISE and press **F5**, or run:

```powershell
.\New-DhcpScopeWizard.ps1
```

You will be asked which DHCP server to manage (Enter = local machine), then
presented with a menu:

1. **Create a new DHCP scope (step-by-step)** — prompts for scope name,
   description, subnet mask, start/end of the range, lease duration,
   activation state, exclusion ranges, scope options, and reservations.
   Any optional step can be skipped by pressing **Enter**.
2. **View existing scopes** — lists all scopes with their utilisation;
   pick one to see its settings, exclusions, options, reservations, and
   statistics. Scopes at or above the warning threshold (default **80%**,
   `$script:UtilWarnThreshold`) are flagged **HIGH** in red.
3. **Export a scope's settings** — writes the full configuration of a scope
   (scope properties, options incl. their definition types, exclusions,
   reservations) to **JSON and/or CSV** in an `Exports\` folder next to the
   script, for review or cloning.
4. **Create a scope from a JSON export (clone)** — pick an export file and
   every value is offered as the default: press Enter to keep it, or type a
   new value (e.g. a different network) to re-IP the clone. Exclusions and
   reservations are shifted automatically by the network offset, and missing
   option definitions (e.g. 150/157) are recreated from the export.
5. **Configure/modify options on an existing scope** — re-runs the option
   wizard against a scope that already exists.
6. **Add reservations to an existing scope** — MAC + IP + name wizard with
   MAC/IP validation and a subnet check (accepts `AA-BB-...`, `AA:BB:...`,
   `AABB.CCDD.EEFF` or bare hex MAC formats).
7. **Change target DHCP server**.
- **D) Toggle dry-run mode** — when ON, nothing is changed on the server;
  every intended change is printed and logged as `WHATIF` instead, so you
  can produce a full change plan for approval before running it for real.

## Scope options handled

| Option | Name                          | Multiple values |
|--------|-------------------------------|-----------------|
| 003    | Router (default gateway)      | Yes             |
| 004    | Time server (RFC 868)         | Yes             |
| 005    | Name servers (IEN-116, legacy)| Yes             |
| 006    | DNS servers                   | Yes             |
| 015    | DNS domain name               | No (string)     |
| 150    | TFTP server (Cisco VoIP)      | Yes             |
| 157    | Vendor-specific (string)      | No (string)     |

Options **150** and **157** are not pre-defined on Windows DHCP servers; the
script detects this and offers to create the option definition automatically
before setting the value.

Multiple values are entered comma-separated, e.g. `10.1.1.1, 10.1.1.2`.

## Safety features

- **IP/MAC validation** — every IP and MAC address is validated before being
  accepted; subnet masks are checked for contiguous bits; the start/end of
  the range must be in the same subnet and correctly ordered; reservation
  IPs are checked against the scope's subnet.
- **Confirmation summary** — the scope is only created after you confirm a
  summary of everything you entered.
- **Dry-run mode** — toggle with `D` in the menu; intended changes are
  logged with level `WHATIF` and nothing is modified on the server.
- **Utilisation warnings** — scopes at or above 80% in-use are flagged in
  the scope list and detail view.
- **Audit logging** — every action (and every skipped step) is written to a
  timestamped log file in a `Logs\` folder next to the script, e.g.
  `Logs\DhcpScopeWizard_20260715_143000.log`, including the username, for
  change control.
