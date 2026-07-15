<#
.SYNOPSIS
    Interactive DHCP scope deployment wizard for Windows Server.

.DESCRIPTION
    Menu-driven, step-by-step tool that:
      1. Creates a new DHCPv4 scope, prompting for all relevant inputs.
         Every optional step can be skipped by pressing Enter.
      2. Configures DHCP scope options 003, 004, 005, 006, 015, 150 and 157.
         Options 003, 004, 005, 006 and 150 accept MULTIPLE entries.
      3. Views existing scopes and their current settings, flagging any
         scope at or above the utilisation warning threshold (default 80%).
      4. Exports an existing scope's full settings to CSV and/or JSON.
      5. Creates (clones) a scope from a JSON export - every exported value
         is offered as a default, so re-IPing a scope is quick. Exclusions
         and reservations are shifted automatically when the network changes.
      6. Adds reservations (MAC + IP + name) to a new or existing scope.
      7. Supports a DRY-RUN mode (toggle with 'D' in the menu): intended
         changes are logged as WHATIF but nothing is changed on the server -
         useful for change-approval paperwork.
      8. Logs every action to a timestamped log file for change control
         and auditing.

    All IP and MAC addresses are validated before they are accepted.

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

# Dry-run mode: when ON, nothing is changed on the server - every intended
# change is logged with level WHATIF instead (useful for change-approval).
# Toggle it from the main menu with 'D'.
$script:DryRun = $false

# Scopes at or above this utilisation percentage are flagged in the view screens.
$script:UtilWarnThreshold = 80

function Write-Log {
    <#
        Writes a message to the console AND to the timestamped log file.
        Levels: INFO, WARN, ERROR, ACTION, WHATIF
        (ACTION = a change was made on the server; WHATIF = dry-run, no change made)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION', 'WHATIF')][string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[{0}] [{1,-6}] [{2}] {3}" -f $stamp, $Level, $env:USERNAME, $Message

    switch ($Level) {
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ACTION' { Write-Host $line -ForegroundColor Green }
        'WHATIF' { Write-Host $line -ForegroundColor Magenta }
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

function ConvertTo-IPString {
    <# Converts a numeric IPv4 value back to a dotted-quad string. #>
    param([int64]$Value)
    $bytes = [BitConverter]::GetBytes([uint32]$Value)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Convert-TranslatedIP {
    <#
        Shifts an IPv4 address by a numeric offset (used when cloning a scope
        onto a different network). Returns $null if the result is out of range.
    #>
    param(
        [string]$IPAddress,
        [int64]$Offset
    )
    if (-not (Test-IPv4Address $IPAddress)) { return $null }
    $value = [int64](ConvertTo-UInt32IP $IPAddress) + $Offset
    if ($value -lt 0 -or $value -gt 4294967295) { return $null }
    return (ConvertTo-IPString $value)
}

function Test-MacAddress {
    <# Accepts AA-BB-CC-DD-EE-FF, AA:BB:..., AABB.CCDD.EEFF or bare 12 hex chars. #>
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $false }
    $clean = $Mac -replace '[-:\.\s]', ''
    return ($clean -match '^[0-9A-Fa-f]{12}$')
}

function ConvertTo-DhcpClientId {
    <# Normalises any accepted MAC notation to AA-BB-CC-DD-EE-FF. #>
    param([string]$Mac)
    $clean = ($Mac -replace '[-:\.\s]', '').ToUpper()
    $pairs = for ($i = 0; $i -lt 12; $i += 2) { $clean.Substring($i, 2) }
    return ($pairs -join '-')
}

function Get-JsonProperty {
    <#
        Safe property read for objects coming out of ConvertFrom-Json
        (StrictMode-friendly: missing properties return the default
        instead of throwing).
    #>
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
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
        [switch]$Force,                                     # skip the Y/N prompt (used by the JSON import)
        [string]$Description = ''
    )

    $existing = Get-DhcpServerv4OptionDefinition -ComputerName $ComputerName -OptionId $OptionId -ErrorAction SilentlyContinue
    if ($existing) { return $true }

    Write-Log "Option $OptionId is not defined on server '$ComputerName'."
    if (-not $Force) {
        if (-not (Read-YesNo -Prompt "Create option definition $OptionId ($Name, type $Type) on the server now?" -Default 'Y')) {
            Write-Log "User declined to create option definition $OptionId - option skipped." 'WARN'
            return $false
        }
    }

    if ($script:DryRun) {
        Write-Log "DRY-RUN: would create option definition $OptionId '$Name' (type $Type) on '$ComputerName'." 'WHATIF'
        return $true
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

    $display = $Value
    if ($Value -is [array]) { $display = $Value -join ', ' }

    if ($script:DryRun) {
        Write-Log "DRY-RUN: scope $ScopeId : would set option $('{0:D3}' -f $OptionId) ($FriendlyName) = $display" 'WHATIF'
        return
    }

    try {
        Set-DhcpServerv4OptionValue -ComputerName $ComputerName -ScopeId $ScopeId `
            -OptionId $OptionId -Value $Value -ErrorAction Stop
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

function New-ScopeFromParameters {
    <#
        Shared scope-creation core used by the interactive wizard and the
        JSON import. Calculates the scope ID, checks for duplicates, shows
        a confirmation summary and creates the scope (dry-run aware).
        Returns the new scope ID string, or $null on failure/cancellation.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$ScopeName,
        [string]$Description = '',
        [Parameter(Mandatory = $true)][string]$Mask,
        [Parameter(Mandatory = $true)][string]$StartIP,
        [Parameter(Mandatory = $true)][string]$EndIP,
        [Parameter(Mandatory = $true)][TimeSpan]$LeaseDuration,
        [bool]$Activate = $true
    )

    # Scope ID = network address derived from the start IP + mask
    $scopeId = ConvertTo-IPString (([int64](ConvertTo-UInt32IP $StartIP)) -band ([int64](ConvertTo-UInt32IP $Mask)))
    Write-Host ("  Calculated scope ID (network address): {0}" -f $scopeId) -ForegroundColor DarkGray

    if (Get-DhcpServerv4Scope -ComputerName $ComputerName -ScopeId $scopeId -ErrorAction SilentlyContinue) {
        Write-Log "A scope with ID $scopeId already exists on '$ComputerName'. Aborting creation." 'ERROR'
        return $null
    }

    $state = 'InActive'
    if ($Activate) { $state = 'Active' }

    Write-Host ""
    Write-Host "  ----------------- SUMMARY -----------------" -ForegroundColor Cyan
    Write-Host ("   Server        : {0}" -f $ComputerName)
    Write-Host ("   Scope name    : {0}" -f $ScopeName)
    Write-Host ("   Description   : {0}" -f $Description)
    Write-Host ("   Scope ID      : {0}" -f $scopeId)
    Write-Host ("   Range         : {0} - {1}" -f $StartIP, $EndIP)
    Write-Host ("   Subnet mask   : {0}" -f $Mask)
    Write-Host ("   Lease duration: {0}" -f $LeaseDuration)
    Write-Host ("   State         : {0}" -f $state)
    if ($script:DryRun) {
        Write-Host "   Mode          : DRY-RUN (no changes will be made)" -ForegroundColor Magenta
    }
    Write-Host "  -------------------------------------------"
    if (-not (Read-YesNo -Prompt "Create this scope now?" -Default 'Y')) {
        Write-Log "Scope creation cancelled by user at summary step." 'WARN'
        return $null
    }

    $describe = "scope $scopeId '$ScopeName' ($StartIP - $EndIP, mask $Mask, lease $LeaseDuration, state $state) on '$ComputerName'"
    if ($script:DryRun) {
        Write-Log "DRY-RUN: would create $describe" 'WHATIF'
        return $scopeId
    }

    try {
        Add-DhcpServerv4Scope -ComputerName $ComputerName -Name $ScopeName -Description $Description `
            -StartRange $StartIP -EndRange $EndIP -SubnetMask $Mask `
            -LeaseDuration $LeaseDuration -State $state -ErrorAction Stop
        Write-Log "Created $describe" 'ACTION'
        return $scopeId
    }
    catch {
        Write-Log ("FAILED to create scope {0}: {1}" -f $scopeId, $_.Exception.Message) 'ERROR'
        return $null
    }
}

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

    # --- Confirmation summary + creation (shared with the JSON import) --------
    $scopeId = New-ScopeFromParameters -ComputerName $ComputerName -ScopeName $scopeName -Description $description `
        -Mask $mask -StartIP $startIP -EndIP $endIP -LeaseDuration $leaseDuration -Activate $activate
    if ($null -eq $scopeId) { return }

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
        if ($script:DryRun) {
            Write-Log "DRY-RUN: scope $scopeId : would add exclusion range $exclStart - $exclEnd." 'WHATIF'
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

    # --- Reservations -----------------------------------------------------------
    Write-Host ""
    if (Read-YesNo -Prompt "Step 10 - Add reservations (fixed IPs for printers/phones) now?" -Default 'N') {
        Add-ReservationsInteractive -ComputerName $ComputerName -ScopeId $scopeId
    } else {
        Write-Log "Scope $scopeId : reservations skipped by user."
    }

    Write-Host ""
    Write-Log "Scope $scopeId deployment finished. Review the log file: $script:LogFile"
}

# =====================================================================
#  RESERVATIONS WIZARD
# =====================================================================

function Add-ReservationsInteractive {
    <#
        Adds reservations (MAC + IP + name) to a scope in a loop.
        Press Enter at the IP prompt to finish.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$ScopeId
    )

    Write-Host ""
    Write-Host "--- Reservations for scope $ScopeId ---" -ForegroundColor Cyan
    Write-Host "    A reservation always leases the same IP to a given MAC address (printers, phones, ...)." -ForegroundColor DarkGray
    Write-Host "    Press Enter at the IP prompt when you are done." -ForegroundColor DarkGray

    # Used to warn when a reservation IP falls outside the scope's subnet.
    # (Not available in dry-run when the scope itself was not really created.)
    $scope = Get-DhcpServerv4Scope -ComputerName $ComputerName -ScopeId $ScopeId -ErrorAction SilentlyContinue

    while ($true) {
        Write-Host ""
        $ip = Read-IPAddressInput -Prompt "Reservation IP address" -AllowSkip
        if ($null -eq $ip) { break }

        if ($scope -and -not (Test-IPInSameSubnet -IPAddress1 $ip -IPAddress2 $ScopeId -Mask $scope.SubnetMask.ToString())) {
            Write-Host "  Warning: $ip is not inside subnet $ScopeId." -ForegroundColor Yellow
            if (-not (Read-YesNo -Prompt "Use it anyway?" -Default 'N')) { continue }
        }

        $mac = $null
        while ($null -eq $mac) {
            $answer = Read-Input -Prompt "MAC address (e.g. 00-1A-2B-3C-4D-5E)" -AllowSkip
            if ($null -eq $answer) { break }
            if (Test-MacAddress $answer) { $mac = ConvertTo-DhcpClientId $answer }
            else { Write-Host "  '$answer' is not a valid MAC address. Please try again." -ForegroundColor Yellow }
        }
        if ($null -eq $mac) { continue }

        $name = Read-Input -Prompt "Reservation name (e.g. PRINTER-01)"
        $desc = Read-Input -Prompt "Reservation description" -AllowSkip
        if ($null -eq $desc) { $desc = '' }

        $describe = "scope $ScopeId : reservation $ip -> $mac ('$name')"
        if ($script:DryRun) {
            Write-Log "DRY-RUN: would add $describe" 'WHATIF'
            continue
        }
        try {
            Add-DhcpServerv4Reservation -ComputerName $ComputerName -ScopeId $ScopeId `
                -IPAddress $ip -ClientId $mac -Name $name -Description $desc -ErrorAction Stop
            Write-Log "Added $describe" 'ACTION'
        }
        catch {
            Write-Log ("FAILED to add {0}: {1}" -f $describe, $_.Exception.Message) 'ERROR'
        }
    }
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

    # Utilisation per scope, so heavily-used scopes can be flagged in the list.
    $statsMap = @{}
    try {
        Get-DhcpServerv4ScopeStatistics -ComputerName $ComputerName -ErrorAction Stop |
            ForEach-Object { $statsMap[$_.ScopeId.ToString()] = [double]$_.PercentageInUse }
    }
    catch { }

    Write-Host ""
    Write-Host ("  {0,-4} {1,-16} {2,-25} {3,-10} {4,-12} {5}" -f '#', 'ScopeId', 'Name', 'State', '%Used', 'Range') -ForegroundColor Cyan
    for ($i = 0; $i -lt $scopes.Count; $i++) {
        $s = $scopes[$i]
        $pct     = $statsMap[$s.ScopeId.ToString()]
        $pctText = 'n/a'
        $color   = 'Gray'
        if ($null -ne $pct) {
            $pctText = '{0:N1}%' -f $pct
            if ($pct -ge $script:UtilWarnThreshold) {
                $pctText += ' HIGH'
                $color = 'Red'
            } else {
                $color = 'Gray'
            }
        }
        Write-Host ("  {0,-4} {1,-16} {2,-25} {3,-10} {4,-12} {5} - {6}" -f ($i + 1), $s.ScopeId, $s.Name, $s.State, $pctText, $s.StartRange, $s.EndRange) -ForegroundColor $color
    }
    Write-Host ("  (scopes at or above {0}% utilisation are flagged HIGH)" -f $script:UtilWarnThreshold) -ForegroundColor DarkGray
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
    if ($stats) {
        $stats | Format-Table Free, InUse, Reserved, PercentageInUse -AutoSize
        if ([double]$stats.PercentageInUse -ge $script:UtilWarnThreshold) {
            Write-Log ("Scope {0} is at {1:N1}% utilisation - at or above the {2}% warning threshold. Consider extending the range or reviewing lease duration." -f `
                $scopeId, [double]$stats.PercentageInUse, $script:UtilWarnThreshold) 'WARN'
        }
    }
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

    # Option definitions are exported alongside the values so the import can
    # recreate non-default definitions (e.g. 150/157) on another server.
    $optionDefs = @{}
    Get-DhcpServerv4OptionDefinition -ComputerName $ComputerName -ErrorAction SilentlyContinue |
        ForEach-Object { $optionDefs[[int]$_.OptionId] = $_ }

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
            $def      = $optionDefs[[int]$_.OptionId]
            $typeName = ''
            $multi    = $false
            if ($def) {
                $typeName = $def.Type.ToString()
                $multi    = [bool]$def.MultiValued
            }
            [PSCustomObject]@{
                OptionId    = $_.OptionId
                Name        = $_.Name
                Type        = $typeName
                MultiValued = $multi
                Value       = @($_.Value)
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
#  4) CREATE A SCOPE FROM A JSON EXPORT (CLONE)
# =====================================================================

function Import-ScopeFromJson {
    <#
        Creates a new scope from a JSON file produced by 'Export a scope'.
        Every exported value is offered as the default - press Enter to keep
        it, or type a new value (e.g. a different network) to re-IP the clone.
        Exclusions and reservations are shifted by the network offset when
        the clone lands on a different network.
    #>
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    # --- Pick the JSON file --------------------------------------------------
    $exportDir = Join-Path $script:ScriptRoot 'Exports'
    $files = @()
    if (Test-Path $exportDir) {
        $files = @(Get-ChildItem -Path $exportDir -Filter '*.json' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
    }

    $jsonPath = $null
    if ($files.Count -gt 0) {
        Write-Host ""
        Write-Host "  Available exports in ${exportDir}:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ("  {0,-4} {1}  ({2:yyyy-MM-dd HH:mm})" -f ($i + 1), $files[$i].Name, $files[$i].LastWriteTime)
        }
        while ($null -eq $jsonPath) {
            $answer = Read-Input -Prompt "Select a file by number, or type a full path" -AllowSkip
            if ($null -eq $answer) { return }
            $index = 0
            if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $files.Count) {
                $jsonPath = $files[$index - 1].FullName
            }
            elseif (Test-Path $answer) { $jsonPath = $answer }
            else { Write-Host "  Not a valid selection or file path." -ForegroundColor Yellow }
        }
    }
    else {
        $jsonPath = Read-Input -Prompt "Path to a scope export JSON file" -AllowSkip
        if ($null -eq $jsonPath) { return }
        if (-not (Test-Path $jsonPath)) {
            Write-Log "File not found: $jsonPath" 'ERROR'
            return
        }
    }

    # --- Parse and validate ----------------------------------------------------
    $data = $null
    try {
        $data = Get-Content -Path $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log ("Could not read/parse '{0}': {1}" -f $jsonPath, $_.Exception.Message) 'ERROR'
        return
    }

    $srcScope = Get-JsonProperty $data 'Scope'
    if ($null -eq $srcScope) {
        Write-Log "'$jsonPath' does not look like a scope export (no 'Scope' section)." 'ERROR'
        return
    }

    $srcScopeId = [string](Get-JsonProperty $srcScope 'ScopeId')
    Write-Log ("Cloning from '{0}' (source scope {1} on {2}, exported {3})." -f `
        $jsonPath, $srcScopeId, (Get-JsonProperty $data 'Server' '?'), (Get-JsonProperty $data 'ExportedAt' '?'))

    # --- Prompt for the new scope, defaulting everything to the export ----------
    Write-Host ""
    Write-Host "=== Clone scope $srcScopeId onto '$ComputerName' ===" -ForegroundColor Cyan
    Write-Host "    Press Enter at each prompt to keep the exported value; type a new one to change it (e.g. to re-IP)." -ForegroundColor DarkGray
    Write-Host ""

    $scopeName   = Read-Input -Prompt "Scope name" -Default ([string](Get-JsonProperty $srcScope 'Name'))
    $description = Read-Input -Prompt "Scope description" -AllowSkip -Default ([string](Get-JsonProperty $srcScope 'Description'))
    if ($null -eq $description) { $description = '' }

    $mask = $null
    while ($null -eq $mask) {
        $candidate = Read-IPAddressInput -Prompt "Subnet mask" -Default ([string](Get-JsonProperty $srcScope 'SubnetMask'))
        if (Test-SubnetMask $candidate) { $mask = $candidate }
        else { Write-Host "  '$candidate' is not a valid subnet mask (bits must be contiguous)." -ForegroundColor Yellow }
    }

    $startIP = $null; $endIP = $null
    while ($true) {
        $startIP = Read-IPAddressInput -Prompt "Start of the address range" -Default ([string](Get-JsonProperty $srcScope 'StartRange'))
        $endIP   = Read-IPAddressInput -Prompt "End of the address range" -Default ([string](Get-JsonProperty $srcScope 'EndRange'))
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

    $leaseDuration = $null
    while ($null -eq $leaseDuration) {
        $leaseText = Read-Input -Prompt "Lease duration (days.hours:minutes)" -Default ([string](Get-JsonProperty $srcScope 'LeaseDuration' '8.00:00'))
        $parsed = New-Object System.TimeSpan
        if ([TimeSpan]::TryParse($leaseText, [ref]$parsed) -and $parsed -gt [TimeSpan]::Zero) { $leaseDuration = $parsed }
        else { Write-Host "  '$leaseText' is not a valid duration. Example: 8.00:00 = 8 days." -ForegroundColor Yellow }
    }

    $activate = Read-YesNo -Prompt "Activate the scope immediately after creation?" -Default 'Y'

    $scopeId = New-ScopeFromParameters -ComputerName $ComputerName -ScopeName $scopeName -Description $description `
        -Mask $mask -StartIP $startIP -EndIP $endIP -LeaseDuration $leaseDuration -Activate $activate
    if ($null -eq $scopeId) { return }

    # Offset used to shift exported exclusion/reservation IPs when the clone
    # landed on a different network.
    $offset = [int64](ConvertTo-UInt32IP $scopeId) - [int64](ConvertTo-UInt32IP $srcScopeId)
    if ($offset -ne 0) {
        Write-Log "New network ($scopeId) differs from the source ($srcScopeId) - exported exclusion/reservation IPs will be shifted by the network offset."
    }

    # --- Exclusions ---------------------------------------------------------------
    $srcExclusions = @(Get-JsonProperty $data 'Exclusions' @())
    if ($srcExclusions.Count -gt 0 -and
        (Read-YesNo -Prompt "Recreate the $($srcExclusions.Count) exported exclusion range(s)?" -Default 'Y')) {
        foreach ($excl in $srcExclusions) {
            $srcStart  = [string](Get-JsonProperty $excl 'StartRange')
            $srcEnd    = [string](Get-JsonProperty $excl 'EndRange')
            $exclStart = Convert-TranslatedIP -IPAddress $srcStart -Offset $offset
            $exclEnd   = Convert-TranslatedIP -IPAddress $srcEnd   -Offset $offset
            if ($null -eq $exclStart -or $null -eq $exclEnd -or
                -not (Test-IPInSameSubnet -IPAddress1 $exclStart -IPAddress2 $scopeId -Mask $mask)) {
                Write-Log "Skipped exclusion $srcStart - $srcEnd : does not translate into subnet $scopeId." 'WARN'
                continue
            }
            if ($script:DryRun) {
                Write-Log "DRY-RUN: scope $scopeId : would add exclusion range $exclStart - $exclEnd." 'WHATIF'
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
    }

    # --- Options ---------------------------------------------------------------------
    $srcOptions = @(Get-JsonProperty $data 'Options' @())
    if ($srcOptions.Count -gt 0 -and
        (Read-YesNo -Prompt "Apply the $($srcOptions.Count) exported scope option(s)?" -Default 'Y')) {

        # When the network changed, IP-type option values (e.g. the gateway)
        # usually need adjusting - default to reviewing each one.
        $adjustDefault = 'N'
        if ($offset -ne 0) { $adjustDefault = 'Y' }
        $adjust = Read-YesNo -Prompt "Review each option value before applying (Enter keeps the exported value)?" -Default $adjustDefault

        foreach ($opt in $srcOptions) {
            $id     = [int](Get-JsonProperty $opt 'OptionId' 0)
            $name   = [string](Get-JsonProperty $opt 'Name' ("Option {0}" -f $id))
            $values = @(@(Get-JsonProperty $opt 'Value' @()) | ForEach-Object { [string]$_ })
            if ($id -le 0 -or $values.Count -eq 0) { continue }

            # Make sure the option definition exists on the target server.
            if (-not (Get-DhcpServerv4OptionDefinition -ComputerName $ComputerName -OptionId $id -ErrorAction SilentlyContinue)) {
                $type  = [string](Get-JsonProperty $opt 'Type' '')
                $multi = [bool](Get-JsonProperty $opt 'MultiValued' $false)
                if ([string]::IsNullOrEmpty($type)) {
                    Write-Log "Option $id ($name) is not defined on '$ComputerName' and the export carries no type information - skipped." 'WARN'
                    continue
                }
                if (-not (Confirm-OptionDefinition -ComputerName $ComputerName -OptionId $id -Name $name `
                        -Type $type -MultiValued:$multi -Force -Description 'Created by scope clone import')) {
                    continue
                }
            }

            if ($adjust) {
                $allIPs = $true
                foreach ($v in $values) { if (-not (Test-IPv4Address $v)) { $allIPs = $false } }
                if ($allIPs) {
                    $newValues = Read-IPAddressListInput -Prompt ("Option {0:D3} - {1} [exported: {2}]" -f $id, $name, ($values -join ', ')) -AllowSkip
                    if ($newValues) { $values = @($newValues) }
                }
                else {
                    $newValue = Read-Input -Prompt ("Option {0:D3} - {1} [exported: {2}] - new value" -f $id, $name, ($values -join ', ')) -AllowSkip
                    if ($newValue) { $values = @($newValue) }
                }
            }

            Set-ScopeOptionSafe -ComputerName $ComputerName -ScopeId $scopeId -OptionId $id -Value $values -FriendlyName $name
        }
    }

    # --- Reservations -------------------------------------------------------------------
    $srcReservations = @(Get-JsonProperty $data 'Reservations' @())
    if ($srcReservations.Count -gt 0 -and
        (Read-YesNo -Prompt "Recreate the $($srcReservations.Count) exported reservation(s) (same MACs, IPs shifted to the new network)?" -Default 'N')) {
        foreach ($res in $srcReservations) {
            $srcIP = [string](Get-JsonProperty $res 'IPAddress')
            $mac   = [string](Get-JsonProperty $res 'ClientId')
            $rname = [string](Get-JsonProperty $res 'Name')
            $rdesc = [string](Get-JsonProperty $res 'Description')
            $resIP = Convert-TranslatedIP -IPAddress $srcIP -Offset $offset
            if ($null -eq $resIP -or -not (Test-IPInSameSubnet -IPAddress1 $resIP -IPAddress2 $scopeId -Mask $mask)) {
                Write-Log "Skipped reservation $srcIP ($mac) : does not translate into subnet $scopeId." 'WARN'
                continue
            }
            $describe = "scope $scopeId : reservation $resIP -> $mac ('$rname')"
            if ($script:DryRun) {
                Write-Log "DRY-RUN: would add $describe" 'WHATIF'
                continue
            }
            try {
                Add-DhcpServerv4Reservation -ComputerName $ComputerName -ScopeId $scopeId `
                    -IPAddress $resIP -ClientId $mac -Name $rname -Description $rdesc -ErrorAction Stop
                Write-Log "Added $describe" 'ACTION'
            }
            catch {
                Write-Log ("FAILED to add {0}: {1}" -f $describe, $_.Exception.Message) 'ERROR'
            }
        }
    }

    if (Read-YesNo -Prompt "Add further reservations interactively?" -Default 'N') {
        Add-ReservationsInteractive -ComputerName $ComputerName -ScopeId $scopeId
    }

    Write-Log "Clone of $srcScopeId -> $scopeId finished. Review the log file: $script:LogFile"
}

# =====================================================================
#  5) EDIT OPTIONS ON AN EXISTING SCOPE
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
    Write-Host "  4) Create a scope from a JSON export (clone)"
    Write-Host "  5) Configure/modify options on an existing scope"
    Write-Host "  6) Add reservations to an existing scope"
    Write-Host "  7) Change target DHCP server"
    $mode = 'OFF'
    if ($script:DryRun) { $mode = 'ON - no changes will be made' }
    Write-Host ("  D) Toggle dry-run mode [currently: {0}]" -f $mode)
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
    if ($script:DryRun) {
        Write-Host "  DRY-RUN MODE IS ON - intended changes are logged but NOT applied." -ForegroundColor Magenta
    }
    $selection = Read-Host "  Select an option"

    switch ($selection.Trim().ToUpper()) {
        '1' { New-DhcpScopeInteractive -ComputerName $dhcpServer }
        '2' { Show-ScopeDetails       -ComputerName $dhcpServer }
        '3' { Export-ScopeSettings    -ComputerName $dhcpServer }
        '4' { Import-ScopeFromJson    -ComputerName $dhcpServer }
        '5' { Edit-ExistingScopeOptions -ComputerName $dhcpServer }
        '6' {
            $scope = Select-ExistingScope -ComputerName $dhcpServer
            if ($scope) { Add-ReservationsInteractive -ComputerName $dhcpServer -ScopeId $scope.ScopeId.ToString() }
        }
        '7' {
            $newServer = Get-TargetDhcpServer
            if ($null -ne $newServer) { $dhcpServer = $newServer }
        }
        'D' {
            $script:DryRun = -not $script:DryRun
            if ($script:DryRun) {
                Write-Log "Dry-run mode ENABLED - no changes will be made to the server; intended changes are logged as WHATIF." 'WHATIF'
            } else {
                Write-Log "Dry-run mode disabled - changes will be applied to the server."
            }
        }
        'Q' { $done = $true }
        default { Write-Host "  Invalid selection." -ForegroundColor Yellow }
    }
}

Write-Log "=== DHCP Scope Wizard finished. ==="
