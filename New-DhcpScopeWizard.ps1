<#
.SYNOPSIS
    Interactive DHCP scope deployment wizard for Windows Server.

.DESCRIPTION
    Menu-driven, step-by-step tool that:
      1. Creates a new DHCPv4 scope, prompting for all relevant inputs.
         Every optional step can be skipped by pressing Enter.
      2. Configures DHCP scope options 003, 004, 005, 006, 015, 150 and 157.
         Options 003, 004, 005, 006 and 150 accept MULTIPLE entries.
      3. Views existing scopes and their current settings.
      4. Exports an existing scope's full settings to CSV and/or JSON
         so it can be reviewed or cloned.
      5. Logs every action to a timestamped log file for change control
         and auditing.

    All IP addresses are validated before they are accepted.

.NOTES
    Compatible with Windows PowerShell 5.x and PowerShell ISE.
    Requires the "DhcpServer" PowerShell module (RSAT-DHCP / DHCP role)
    and must be run in an elevated (Administrator) session to make changes.

    Run it, then follow the menu.
#>

#Requires -Version 5.0

Set-StrictMode -Version 2.0

# =====================================================================
#  GLOBALS / LOGGING
# =====================================================================

# $MyInvocation.MyCommand.Path is empty when the script is run from an
# unsaved ISE tab or pasted into the console - fall back to the current dir.
$script:ScriptRoot = $null
try { $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -ErrorAction Stop } catch { }
if ([string]::IsNullOrEmpty($script:ScriptRoot)) { $script:ScriptRoot = (Get-Location).Path }

$script:LogDir  = Join-Path $script:ScriptRoot 'Logs'
if (-not (Test-Path $script:LogDir)) {
    New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
}
$script:LogFile = Join-Path $script:LogDir ("DhcpScopeWizard_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    <#
        Writes a message to the console AND to the timestamped log file.
        Levels: INFO, WARN, ERROR, ACTION (ACTION = a change was made on the server)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[{0}] [{1,-6}] [{2}] {3}" -f $stamp, $Level, $env:USERNAME, $Message

    switch ($Level) {
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ACTION' { Write-Host $line -ForegroundColor Green }
        default  { Write-Host $line -ForegroundColor Gray }
    }

    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

# =====================================================================
#  VALIDATION HELPERS
# =====================================================================

function Test-IPv4Address {
    <# Returns $true only for a syntactically valid IPv4 dotted-quad address. #>
    param([string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $false }

    # [ipaddress] alone accepts shorthand like "10.1" - enforce 4 octets explicitly.
    $octets = $IPAddress.Trim() -split '\.'
    if ($octets.Count -ne 4) { return $false }

    foreach ($octet in $octets) {
        $value = 0
        if (-not [int]::TryParse($octet, [ref]$value)) { return $false }
        if ($value -lt 0 -or $value -gt 255) { return $false }
        # Reject leading zeros like 010 (ambiguous / often a typo)
        if ($octet.Length -gt 1 -and $octet.StartsWith('0')) { return $false }
    }
    return $true
}

function Test-SubnetMask {
    <# Valid IPv4 mask = contiguous 1-bits followed by contiguous 0-bits. #>
    param([string]$Mask)

    if (-not (Test-IPv4Address $Mask)) { return $false }

    $bytes = ([System.Net.IPAddress]::Parse($Mask)).GetAddressBytes()
    $binary = ''
    foreach ($b in $bytes) { $binary += [Convert]::ToString($b, 2).PadLeft(8, '0') }

    # No "01" transition allowed anywhere (e.g. 255.0.255.0 is invalid)
    return ($binary -notmatch '01')
}

function ConvertTo-UInt32IP {
    <# Converts an IPv4 string to a UInt32 so ranges can be compared. #>
    param([string]$IPAddress)
    $bytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPInSameSubnet {
    <# Checks that two IPs fall in the same subnet for a given mask. #>
    param(
        [string]$IPAddress1,
        [string]$IPAddress2,
        [string]$Mask
    )
    $ip1  = ConvertTo-UInt32IP $IPAddress1
    $ip2  = ConvertTo-UInt32IP $IPAddress2
    $m    = ConvertTo-UInt32IP $Mask
    return (($ip1 -band $m) -eq ($ip2 -band $m))
}

# =====================================================================
#  INPUT HELPERS (all support skipping where allowed)
# =====================================================================

function Read-Input {
    <#
        Generic prompt. Returns $null when the user skips (blank input)
        and skipping is allowed; otherwise keeps prompting.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [switch]$AllowSkip,
        [string]$Default
    )

    while ($true) {
        $suffix = ''
        if (-not [string]::IsNullOrEmpty($Default)) { $suffix = " [default: $Default]" }
        elseif ($AllowSkip) { $suffix = " (press Enter to skip)" }

        $answer = Read-Host ("  {0}{1}" -f $Prompt, $suffix)

        if ([string]::IsNullOrWhiteSpace($answer)) {
            if (-not [string]::IsNullOrEmpty($Default)) { return $Default }
            if ($AllowSkip) { return $null }
            Write-Host "  A value is required here." -ForegroundColor Yellow
            continue
        }
        return $answer.Trim()
    }
}

function Read-IPAddressInput {
    <# Prompts for ONE IPv4 address, validating it. Returns $null on skip. #>
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [switch]$AllowSkip,
        [string]$Default
    )

    while ($true) {
        $answer = Read-Input -Prompt $Prompt -AllowSkip:$AllowSkip -Default $Default
        if ($null -eq $answer) { return $null }
        if (Test-IPv4Address $answer) { return $answer }
        Write-Host "  '$answer' is not a valid IPv4 address. Please try again." -ForegroundColor Yellow
    }
}

function Read-IPAddressListInput {
    <#
        Prompts for ONE OR MORE IPv4 addresses (comma or space separated).
        Every address is validated; re-prompts if any entry is invalid.
        Returns a string array, or $null on skip.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [switch]$AllowSkip
    )

    while ($true) {
        $answer = Read-Input -Prompt ("{0} (multiple allowed, comma-separated)" -f $Prompt) -AllowSkip:$AllowSkip
        if ($null -eq $answer) { return $null }

        $candidates = @($answer -split '[,;\s]+' | Where-Object { $_ -ne '' })
        if ($candidates.Count -eq 0) {
            Write-Host "  No addresses recognised. Please try again." -ForegroundColor Yellow
            continue
        }

        $invalid = @($candidates | Where-Object { -not (Test-IPv4Address $_) })
        if ($invalid.Count -gt 0) {
            Write-Host ("  Invalid IPv4 address(es): {0}. Please re-enter the full list." -f ($invalid -join ', ')) -ForegroundColor Yellow
            continue
        }
        return @($candidates)
    }
}

function Read-YesNo {
    <# Simple Y/N prompt with a default. Returns $true / $false. #>
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [ValidateSet('Y', 'N')][string]$Default = 'N'
    )

    while ($true) {
        $answer = Read-Host ("  {0} (Y/N) [default: {1}]" -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        switch ($answer.Trim().ToUpper()) {
            'Y' { return $true }
            'N' { return $false }
            default { Write-Host "  Please answer Y or N." -ForegroundColor Yellow }
        }
    }
}

# =====================================================================
#  ENVIRONMENT CHECKS
# =====================================================================

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Log "Session is NOT elevated. Viewing may work, but changes will fail. Re-run PowerShell/ISE as Administrator." 'WARN'
    }

    if (-not (Get-Module -ListAvailable -Name DhcpServer)) {
        Write-Log "The 'DhcpServer' PowerShell module is not installed. Install the DHCP role or RSAT DHCP tools (Install-WindowsFeature RSAT-DHCP)." 'ERROR'
        return $false
    }

    try {
        Import-Module DhcpServer -ErrorAction Stop
        Write-Log "DhcpServer module loaded."
        return $true
    }
    catch {
        Write-Log ("Failed to load DhcpServer module: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-TargetDhcpServer {
    <# Asks which DHCP server to manage. Blank = local server. #>
    $server = Read-Input -Prompt "DHCP server to manage (hostname/FQDN)" -Default $env:COMPUTERNAME
    try {
        Get-DhcpServerv4Scope -ComputerName $server -ErrorAction Stop | Out-Null
        Write-Log "Connected to DHCP server '$server'."
    }
    catch {
        # An empty scope list also throws nothing; a real failure lands here.
        Write-Log ("Could not query DHCP server '{0}': {1}" -f $server, $_.Exception.Message) 'WARN'
        if (-not (Read-YesNo -Prompt "Continue with server '$server' anyway?" -Default 'N')) {
            return $null
        }
    }
    return $server
}

# =====================================================================
#  OPTION DEFINITIONS (needed for 150 / 157 which Windows lacks by default)
# =====================================================================

function Confirm-OptionDefinition {
    <#
        Ensures an option definition exists on the server; creates it if missing.
        Windows DHCP does not pre-define options 150 and 157.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$OptionId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Type,        # e.g. IPv4Address / String
        [switch]$MultiValued,
        [string]$Description = ''
    )

    $existing = Get-DhcpServerv4OptionDefinition -ComputerName $ComputerName -OptionId $OptionId -ErrorAction SilentlyContinue
    if ($existing) { return $true }

    Write-Log "Option $OptionId is not defined on server '$ComputerName'."
    if (-not (Read-YesNo -Prompt "Create option definition $OptionId ($Name, type $Type) on the server now?" -Default 'Y')) {
        Write-Log "User declined to create option definition $OptionId - option skipped." 'WARN'
        return $false
    }

    try {
        Add-DhcpServerv4OptionDefinition -ComputerName $ComputerName -OptionId $OptionId `
            -Name $Name -Type $Type -MultiValued:$MultiValued -Description $Description -ErrorAction Stop
        Write-Log "Created option definition $OptionId '$Name' (type $Type) on '$ComputerName'." 'ACTION'
        return $true
    }
    catch {
        Write-Log ("Failed to create option definition {0}: {1}" -f $OptionId, $_.Exception.Message) 'ERROR'
        return $false
    }
}

# =====================================================================
#  SCOPE OPTION CONFIGURATION (003, 004, 005, 006, 015, 150, 157)
# =====================================================================

function Set-ScopeOptionSafe {
    <# Wraps Set-DhcpServerv4OptionValue with logging + error handling. #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][int]$OptionId,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )

    try {
        Set-DhcpServerv4OptionValue -ComputerName $ComputerName -ScopeId $ScopeId `
            -OptionId $OptionId -Value $Value -ErrorAction Stop
        $display = $Value
        if ($Value -is [array]) { $display = $Value -join ', ' }
        Write-Log "Scope $ScopeId : set option $('{0:D3}' -f $OptionId) ($FriendlyName) = $display" 'ACTION'
    }
    catch {
        Write-Log ("Scope {0} : FAILED to set option {1} ({2}): {3}" -f $ScopeId, $OptionId, $FriendlyName, $_.Exception.Message) 'ERROR'
    }
}

function Invoke-ScopeOptionWizard {
    <#
        Walks through options 003, 004, 006, 015, 150, 005, 157 for a scope.
        Every option can be skipped by pressing Enter.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$ScopeId
    )

    Write-Host ""
    Write-Host "--- DHCP scope options for scope $ScopeId ---" -ForegroundColor Cyan
    Write-Host "    Press Enter at any option to skip it." -ForegroundColor DarkGray
    Write-Host ""

    # ---- 003 Router (default gateway) - multiple allowed -------------
    $routers = Read-IPAddressListInput -Prompt "Option 003 - Router / default gateway" -AllowSkip
    if ($routers) {
        Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 3 -Value $routers -FriendlyName 'Router'
    } else { Write-Log "Scope $ScopeId : option 003 (Router) skipped." }

    # ---- 004 Time Server - multiple allowed ---------------------------
    $timeServers = Read-IPAddressListInput -Prompt "Option 004 - Time server (RFC 868)" -AllowSkip
    if ($timeServers) {
        Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 4 -Value $timeServers -FriendlyName 'Time Server'
    } else { Write-Log "Scope $ScopeId : option 004 (Time Server) skipped." }

    # ---- 006 DNS Servers - multiple allowed ---------------------------
    $dnsServers = Read-IPAddressListInput -Prompt "Option 006 - DNS servers" -AllowSkip
    if ($dnsServers) {
        Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 6 -Value $dnsServers -FriendlyName 'DNS Servers'
    } else { Write-Log "Scope $ScopeId : option 006 (DNS Servers) skipped." }

    # ---- 015 DNS Domain Name - single string --------------------------
    $domain = Read-Input -Prompt "Option 015 - DNS domain name (e.g. corp.contoso.com)" -AllowSkip
    if ($domain) {
        Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 15 -Value $domain -FriendlyName 'DNS Domain Name'
    } else { Write-Log "Scope $ScopeId : option 015 (DNS Domain Name) skipped." }

    # ---- 150 TFTP Server (Cisco VoIP) - multiple allowed --------------
    # Not defined by default on Windows DHCP - create the definition first.
    Write-Host "  (Option 150 is commonly used for Cisco IP phone TFTP servers.)" -ForegroundColor DarkGray
    $tftpServers = Read-IPAddressListInput -Prompt "Option 150 - TFTP server address(es)" -AllowSkip
    if ($tftpServers) {
        $defOk = Confirm-OptionDefinition -ComputerName $ComputerName -OptionId 150 `
            -Name 'TFTP Server Address' -Type 'IPv4Address' -MultiValued `
            -Description 'TFTP server address (Cisco IP telephony)'
        if ($defOk) {
            Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 150 -Value $tftpServers -FriendlyName 'TFTP Server'
        }
    } else { Write-Log "Scope $ScopeId : option 150 (TFTP Server) skipped." }

    # ---- 005 Name Servers (IEN-116) - multiple allowed ----------------
    Write-Host "  (Option 005 is the legacy IEN-116 name server - rarely needed; DNS is option 006.)" -ForegroundColor DarkGray
    $nameServers = Read-IPAddressListInput -Prompt "Option 005 - Name servers (IEN-116)" -AllowSkip
    if ($nameServers) {
        Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 5 -Value $nameServers -FriendlyName 'Name Servers'
    } else { Write-Log "Scope $ScopeId : option 005 (Name Servers) skipped." }

    # ---- 157 - vendor / site specific, entered as a string ------------
    # Not defined by default on Windows DHCP. Frequently used by VoIP vendors
    # (e.g. Mitel/ShoreTel configuration strings).
    Write-Host "  (Option 157 is vendor-specific - often a configuration string for IP phones.)" -ForegroundColor DarkGray
    $opt157 = Read-Input -Prompt "Option 157 - value (string)" -AllowSkip
    if ($opt157) {
        $defOk = Confirm-OptionDefinition -ComputerName $ComputerName -OptionId 157 `
            -Name 'Vendor Specific 157' -Type 'String' `
            -Description 'Vendor-specific option 157 (e.g. VoIP configuration string)'
        if ($defOk) {
            Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $ScopeId -OptionId 157 -Value $opt157 -FriendlyName 'Vendor Specific 157'
        }
    } else { Write-Log "Scope $ScopeId : option 157 skipped." }
}

# =====================================================================
#  1) CREATE A NEW SCOPE (step-by-step)
# =====================================================================

function New-DhcpScopeInteractive {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    Write-Host ""
    Write-Host "=== Create a new DHCPv4 scope on '$ComputerName' ===" -ForegroundColor Cyan
    Write-Host ""

    # --- Step 1: identity ------------------------------------------------
    $scopeName   = Read-Input -Prompt "Step 1  - Scope name"
    $description = Read-Input -Prompt "Step 2  - Scope description" -AllowSkip
    if ($null -eq $description) { $description = '' }

    # --- Step 2: subnet mask ----------------------------------------------
    $mask = $null
    while ($null -eq $mask) {
        $candidate = Read-IPAddressInput -Prompt "Step 3  - Subnet mask (e.g. 255.255.255.0)"
        if (Test-SubnetMask $candidate) { $mask = $candidate }
        else { Write-Host "  '$candidate' is not a valid subnet mask (bits must be contiguous)." -ForegroundColor Yellow }
    }

    # --- Step 3: address range, validated against the mask ----------------
    $startIP = $null; $endIP = $null
    while ($true) {
        $startIP = Read-IPAddressInput -Prompt "Step 4  - Start of the address range (e.g. 10.10.10.50)"
        $endIP   = Read-IPAddressInput -Prompt "Step 5  - End of the address range   (e.g. 10.10.10.200)"

        if (-not (Test-IPInSameSubnet -IPAddress1 $startIP -IPAddress2 $endIP -Mask $mask)) {
            Write-Host "  Start and end addresses are not in the same subnet for mask $mask. Please re-enter." -ForegroundColor Yellow
            continue
        }
        if ((ConvertTo-UInt32IP $startIP) -gt (ConvertTo-UInt32IP $endIP)) {
            Write-Host "  The start address is higher than the end address. Please re-enter." -ForegroundColor Yellow
            continue
        }
        break
    }

    # Scope ID = network address derived from the start IP + mask
    $scopeIdUint = (ConvertTo-UInt32IP $startIP) -band (ConvertTo-UInt32IP $mask)
    $scopeBytes  = [BitConverter]::GetBytes($scopeIdUint)
    [Array]::Reverse($scopeBytes)
    $scopeId     = ([System.Net.IPAddress]::new($scopeBytes)).ToString()
    Write-Host ("  Calculated scope ID (network address): {0}" -f $scopeId) -ForegroundColor DarkGray

    if (Get-DhcpServerv4Scope -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue) {
        Write-Log "A scope with ID $scopeId already exists on '$ComputerName'. Aborting creation." 'ERROR'
        return
    }

    # --- Step 4: lease duration -------------------------------------------
    $leaseDuration = $null
    while ($null -eq $leaseDuration) {
        $leaseText = Read-Input -Prompt "Step 6  - Lease duration in days.hours:minutes (e.g. 8.00:00)" -Default '8.00:00'
        $parsed = New-Object System.TimeSpan
        if ([TimeSpan]::TryParse($leaseText, [ref]$parsed) -and $parsed -gt [TimeSpan]::Zero) {
            $leaseDuration = $parsed
        } else {
            Write-Host "  '$leaseText' is not a valid duration. Example: 8.00:00 = 8 days." -ForegroundColor Yellow
        }
    }

    # --- Step 5: activate now? ---------------------------------------------
    $activate = Read-YesNo -Prompt "Step 7  - Activate the scope immediately after creation?" -Default 'Y'
    $state = 'InActive'
    if ($activate) { $state = 'Active' }

    # --- Confirmation summary ------------------------------------------------
    Write-Host ""
    Write-Host "  ----------------- SUMMARY -----------------" -ForegroundColor Cyan
    Write-Host ("   Server        : {0}" -f $ComputerName)
    Write-Host ("   Scope name    : {0}" -f $scopeName)
    Write-Host ("   Description   : {0}" -f $description)
    Write-Host ("   Scope ID      : {0}" -f $scopeId)
    Write-Host ("   Range         : {0} - {1}" -f $startIP, $endIP)
    Write-Host ("   Subnet mask   : {0}" -f $mask)
    Write-Host ("   Lease duration: {0}" -f $leaseDuration)
    Write-Host ("   State         : {0}" -f $state)
    Write-Host "  -------------------------------------------"
    if (-not (Read-YesNo -Prompt "Create this scope now?" -Default 'Y')) {
        Write-Log "Scope creation cancelled by user at summary step." 'WARN'
        return
    }

    # --- Create the scope ------------------------------------------------------
    try {
        Add-DhcpServerv4Scope -ComputerName $ComputerName -Name $scopeName -Description $description `
            -StartRange $startIP -EndRange $endIP -SubnetMask $mask `
            -LeaseDuration $leaseDuration -State $state -ErrorAction Stop
        Write-Log "Created scope $scopeId '$scopeName' ($startIP - $endIP, mask $mask, lease $leaseDuration, state $state) on '$ComputerName'." 'ACTION'
    }
    catch {
        Write-Log ("FAILED to create scope {0}: {1}" -f $scopeId, $_.Exception.Message) 'ERROR'
        return
    }

    # --- Exclusion ranges (optional, multiple) -----------------------------------
    Write-Host ""
    Write-Host "Step 8  - Exclusion ranges (addresses inside the range the server must NOT lease)." -ForegroundColor Cyan
    while (Read-YesNo -Prompt "Add an exclusion range?" -Default 'N') {
        $exclStart = Read-IPAddressInput -Prompt "  Exclusion start IP"
        $exclEnd   = Read-IPAddressInput -Prompt "  Exclusion end IP" -Default $exclStart
        if ((ConvertTo-UInt32IP $exclStart) -gt (ConvertTo-UInt32IP $exclEnd)) {
            Write-Host "  Exclusion start is higher than exclusion end - not added." -ForegroundColor Yellow
            continue
        }
        try {
            Add-DhcpServerv4ExclusionRange -ComputerName $ComputerName -ScopeId $scopeId `
                -StartRange $exclStart -EndRange $exclEnd -ErrorAction Stop
            Write-Log "Scope $scopeId : added exclusion range $exclStart - $exclEnd." 'ACTION'
        }
        catch {
            Write-Log ("Scope {0} : FAILED to add exclusion {1}-{2}: {3}" -f $scopeId, $exclStart, $exclEnd, $_.Exception.Message) 'ERROR'
        }
    }

    # --- Scope options -------------------------------------------------------------
    Write-Host ""
    if (Read-YesNo -Prompt "Step 9  - Configure scope options (003/004/005/006/015/150/157) now?" -Default 'Y') {
        Invoke-ScopeOptionWizard -ComputerName $ComputerName -ScopeId $scopeId
    } else {
        Write-Log "Scope $scopeId : option configuration skipped by user."
    }

    Write-Host ""
    Write-Log "Scope $scopeId deployment finished. Review the log file: $script:LogFile"
}

# =====================================================================
#  2) VIEW EXISTING SCOPES
# =====================================================================

function Select-ExistingScope {
    <# Lists scopes and lets the user pick one. Returns the scope object or $null. #>
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $scopes = @(Get-DhcpServerv4Scope -ComputerName $ComputerName -ErrorAction SilentlyContinue)
    if ($scopes.Count -eq 0) {
        Write-Log "No DHCPv4 scopes found on '$ComputerName'." 'WARN'
        return $null
    }

    Write-Host ""
    Write-Host ("  {0,-4} {1,-16} {2,-25} {3,-10} {4}" -f '#', 'ScopeId', 'Name', 'State', 'Range') -ForegroundColor Cyan
    for ($i = 0; $i -lt $scopes.Count; $i++) {
        $s = $scopes[$i]
        Write-Host ("  {0,-4} {1,-16} {2,-25} {3,-10} {4} - {5}" -f ($i + 1), $s.ScopeId, $s.Name, $s.State, $s.StartRange, $s.EndRange)
    }
    Write-Host ""

    while ($true) {
        $answer = Read-Input -Prompt "Select a scope by number" -AllowSkip
        if ($null -eq $answer) { return $null }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $scopes.Count) {
            return $scopes[$index - 1]
        }
        Write-Host "  Enter a number between 1 and $($scopes.Count), or press Enter to cancel." -ForegroundColor Yellow
    }
}

function Show-ScopeDetails {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $scope = Select-ExistingScope -ComputerName $ComputerName
    if ($null -eq $scope) { return }

    $scopeId = $scope.ScopeId.ToString()
    Write-Log "Viewing settings of scope $scopeId on '$ComputerName'."

    Write-Host ""
    Write-Host "=== Scope $scopeId - '$($scope.Name)' ===" -ForegroundColor Cyan
    $scope | Format-List Name, Description, ScopeId, SubnetMask, StartRange, EndRange, State, LeaseDuration, Type

    Write-Host "--- Exclusion ranges ---" -ForegroundColor Cyan
    $exclusions = @(Get-DhcpServerv4ExclusionRange -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue)
    if ($exclusions.Count -gt 0) { $exclusions | Format-Table StartRange, EndRange -AutoSize }
    else { Write-Host "  (none)" -ForegroundColor DarkGray }

    Write-Host "--- Scope options ---" -ForegroundColor Cyan
    $options = @(Get-DhcpServerv4OptionValue -ComputerName $ComputerName -ScopeId $scopeId -All -ErrorAction SilentlyContinue)
    if ($options.Count -gt 0) {
        $options | Sort-Object OptionId | Format-Table @{ Label = 'ID'; Expression = { '{0:D3}' -f $_.OptionId } },
            Name, @{ Label = 'Value'; Expression = { $_.Value -join ', ' } } -AutoSize
    } else { Write-Host "  (none)" -ForegroundColor DarkGray }

    Write-Host "--- Reservations ---" -ForegroundColor Cyan
    $reservations = @(Get-DhcpServerv4Reservation -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue)
    if ($reservations.Count -gt 0) { $reservations | Format-Table IPAddress, ClientId, Name, Description -AutoSize }
    else { Write-Host "  (none)" -ForegroundColor DarkGray }

    Write-Host "--- Utilisation ---" -ForegroundColor Cyan
    $stats = Get-DhcpServerv4ScopeStatistics -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue
    if ($stats) { $stats | Format-Table Free, InUse, Reserved, PercentageInUse -AutoSize }
    else { Write-Host "  (statistics not available)" -ForegroundColor DarkGray }
}

# =====================================================================
#  3) EXPORT SCOPE SETTINGS (CSV / JSON) FOR CLONING
# =====================================================================

function Export-ScopeSettings {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $scope = Select-ExistingScope -ComputerName $ComputerName
    if ($null -eq $scope) { return }
    $scopeId = $scope.ScopeId.ToString()

    $exclusions   = @(Get-DhcpServerv4ExclusionRange -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue)
    $options      = @(Get-DhcpServerv4OptionValue   -ComputerName $ComputerName -ScopeId $scopeId -All -ErrorAction SilentlyContinue)
    $reservations = @(Get-DhcpServerv4Reservation   -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue)

    $export = [PSCustomObject]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ExportedBy    = $env:USERNAME
        Server        = $ComputerName
        Scope         = [PSCustomObject]@{
            Name          = $scope.Name
            Description   = $scope.Description
            ScopeId       = $scopeId
            SubnetMask    = $scope.SubnetMask.ToString()
            StartRange    = $scope.StartRange.ToString()
            EndRange      = $scope.EndRange.ToString()
            State         = $scope.State
            LeaseDuration = $scope.LeaseDuration.ToString()
        }
        Exclusions    = @($exclusions | ForEach-Object {
            [PSCustomObject]@{ StartRange = $_.StartRange.ToString(); EndRange = $_.EndRange.ToString() }
        })
        Options       = @($options | Sort-Object OptionId | ForEach-Object {
            [PSCustomObject]@{
                OptionId = $_.OptionId
                Name     = $_.Name
                Value    = @($_.Value)
            }
        })
        Reservations  = @($reservations | ForEach-Object {
            [PSCustomObject]@{
                IPAddress   = $_.IPAddress.ToString()
                ClientId    = $_.ClientId
                Name        = $_.Name
                Description = $_.Description
            }
        })
    }

    $exportDir = Join-Path $script:ScriptRoot 'Exports'
    if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $baseName = Join-Path $exportDir ("Scope_{0}_{1}" -f ($scopeId -replace '\.', '-'), $stamp)

    Write-Host ""
    Write-Host "  Export format:" -ForegroundColor Cyan
    Write-Host "    1) JSON (full fidelity - best for cloning)"
    Write-Host "    2) CSV  (flat files - scope, options, exclusions, reservations)"
    Write-Host "    3) Both"
    $choice = Read-Input -Prompt "Choose 1, 2 or 3" -Default '3'

    if ($choice -eq '1' -or $choice -eq '3') {
        $jsonPath = "$baseName.json"
        $export | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Log "Exported scope $scopeId settings to JSON: $jsonPath" 'ACTION'
    }

    if ($choice -eq '2' -or $choice -eq '3') {
        # CSV cannot hold nested data, so write one flat file per section.
        $export.Scope | Select-Object @{ n = 'Server'; e = { $ComputerName } }, * |
            Export-Csv -Path "$baseName`_Scope.csv" -NoTypeInformation -Encoding UTF8

        if ($export.Options.Count -gt 0) {
            $export.Options | Select-Object OptionId, Name, @{ n = 'Value'; e = { $_.Value -join ';' } } |
                Export-Csv -Path "$baseName`_Options.csv" -NoTypeInformation -Encoding UTF8
        }
        if ($export.Exclusions.Count -gt 0) {
            $export.Exclusions | Export-Csv -Path "$baseName`_Exclusions.csv" -NoTypeInformation -Encoding UTF8
        }
        if ($export.Reservations.Count -gt 0) {
            $export.Reservations | Export-Csv -Path "$baseName`_Reservations.csv" -NoTypeInformation -Encoding UTF8
        }
        Write-Log "Exported scope $scopeId settings to CSV files with prefix: $baseName" 'ACTION'
    }
}

# =====================================================================
#  4) EDIT OPTIONS ON AN EXISTING SCOPE
# =====================================================================

function Edit-ExistingScopeOptions {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $scope = Select-ExistingScope -ComputerName $ComputerName
    if ($null -eq $scope) { return }
    Invoke-ScopeOptionWizard -ComputerName $ComputerName -ScopeId $scope.ScopeId.ToString()
}

# =====================================================================
#  MAIN MENU
# =====================================================================

function Show-Menu {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "        DHCP SCOPE DEPLOYMENT WIZARD" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  1) Create a new DHCP scope (step-by-step)"
    Write-Host "  2) View existing scopes and their settings"
    Write-Host "  3) Export a scope's settings (CSV/JSON) for cloning"
    Write-Host "  4) Configure/modify options on an existing scope"
    Write-Host "  5) Change target DHCP server"
    Write-Host "  Q) Quit"
    Write-Host ""
}

# ---------------------------------------------------------------------
#  Entry point
# ---------------------------------------------------------------------

Write-Log "=== DHCP Scope Wizard started. Log file: $script:LogFile ==="

if (-not (Test-Prerequisites)) {
    Write-Log "Prerequisites not met - exiting." 'ERROR'
    return
}

$dhcpServer = Get-TargetDhcpServer
if ($null -eq $dhcpServer) {
    Write-Log "No DHCP server selected - exiting." 'WARN'
    return
}

$done = $false
while (-not $done) {
    Show-Menu
    Write-Host ("  Target server: {0}" -f $dhcpServer) -ForegroundColor DarkGray
    $selection = Read-Host "  Select an option"

    switch ($selection.Trim().ToUpper()) {
        '1' { New-DhcpScopeInteractive -ComputerName $dhcpServer }
        '2' { Show-ScopeDetails       -ComputerName $dhcpServer }
        '3' { Export-ScopeSettings    -ComputerName $dhcpServer }
        '4' { Edit-ExistingScopeOptions -ComputerName $dhcpServer }
        '5' {
            $newServer = Get-TargetDhcpServer
            if ($null -ne $newServer) { $dhcpServer = $newServer }
        }
        'Q' { $done = $true }
        default { Write-Host "  Invalid selection." -ForegroundColor Yellow }
    }
}

Write-Log "=== DHCP Scope Wizard finished. ==="
