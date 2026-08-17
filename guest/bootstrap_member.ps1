# HyperVLabKit guest bootstrap: MEMBER server - static IP, wait for the DC,
# join the domain. Roles are added afterwards via Install-LabGuestTask.
# Copy into labs/<lab>/guest/, edit CONFIG, stage on host, pass to New-LabVM.

# --- CONFIG (edit per lab) ---
$VmTag     = 'SRV01'
$IP        = '10.80.0.20'
$Prefix    = 24
$Gateway   = '10.80.0.1'
$DnsServer = '10.80.0.10'    # a DC
$Domain    = 'research.lab'
$NetBios   = 'RESEARCH'
# --- END CONFIG ---

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $stateFile = "$dir\state.txt"; $log = "$dir\bootstrap.log"
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) {
    try { New-Item -Path $kvpKey -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Set-ItemProperty -Path $kvpKey -Name 'LabStatus' -Value $s -ErrorAction SilentlyContinue } catch {}
    Log "STATUS=$s"
}
$step = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { 'start' }
Log "=== fired, step=$step ==="

if ($step -eq 'start') {
    Status "$VmTag|bootstrap|waiting-setup"
    for ($i = 0; $i -lt 90; $i++) {
        $sip  = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name SystemSetupInProgress -ErrorAction SilentlyContinue).SystemSetupInProgress
        $oobe = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -ErrorAction SilentlyContinue).OOBEInProgress
        if (($sip -ne 1) -and ($oobe -ne 1)) { Log 'setup finalized'; break }
        Start-Sleep 10
    }
    Status "$VmTag|bootstrap|network"
    # hard gate: joining a domain without a NIC cannot work
    $ifc = $null
    for ($i = 0; $i -lt 30; $i++) {
        $ifc = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if ($ifc) { break }
        Start-Sleep 10
    }
    if (-not $ifc) { Log 'no NIC in Up state'; Status "$VmTag|bootstrap|no-nic"; return }
    try {
        Get-NetIPAddress -InterfaceIndex $ifc.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $ifc.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $ifc.ifIndex -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $ifc.ifIndex -ServerAddresses $DnsServer
        Log "static IP $IP, DNS $DnsServer set on $($ifc.Name)"
    } catch {
        Log ('net cfg ERROR: ' + $_.Exception.Message)
        Status "$VmTag|bootstrap|net-error"
        return
    }
    try {
        # keep Windows Update from grabbing CBS during role installs
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Name 'UseWindowsUpdate' -Type DWord -Value 2 -ErrorAction SilentlyContinue
    } catch {}
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    Status "$VmTag|bootstrap|waiting-dc"
    # DNS answering is NOT enough: a DC serves DNS long before AD is usable, and
    # a join at that moment fails with "domain could not be contacted". Wait for
    # the SRV records netlogon publishes plus LDAP.
    $dcUp = $false
    for ($i = 0; $i -lt 90; $i++) {
        try {
            $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$Domain" -Type SRV -Server $DnsServer -ErrorAction Stop
            $ldap = Test-NetConnection -ComputerName $DnsServer -Port 389 -WarningAction SilentlyContinue
            if ($srv -and $ldap.TcpTestSucceeded) { $dcUp = $true; break }
        } catch { }
        Start-Sleep 20
    }
    if (-not $dcUp) { Log 'AD not reachable yet'; Status "$VmTag|bootstrap|dc-not-ready"; return }
    # write next state BEFORE joining: Add-Computer reboots the machine
    Set-Content $stateFile 'joined'
    Status "$VmTag|bootstrap|joining"
    # Retry the join itself rather than trying to predict when AD is ready.
    # SRV records and LDAP answer minutes before the domain actually accepts a
    # join, so every readiness probe is a guess; attempting the real operation
    # is the only honest test. The scheduled task retry stays as an outer net.
    $sec  = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential("$NetBios\Administrator", $sec)
    for ($try = 1; $try -le 15; $try++) {
        try {
            Add-Computer -DomainName $Domain -Credential $cred -Force -Restart -ErrorAction Stop
            Log "Add-Computer issued on attempt $try (reboot expected)"
            return
        } catch {
            Log ("join attempt $try failed: " + $_.Exception.Message)
            Status "$VmTag|bootstrap|joining-retry-$try"
            Start-Sleep 60
        }
    }
    Log 'join did not succeed after 15 attempts'
    Status "$VmTag|bootstrap|join-error"
    Set-Content $stateFile 'start'
    return
}

if ($step -eq 'joined') {
    Status "$VmTag|bootstrap|verify"
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $Domain) {
        Set-Content $stateFile 'done'
        Status "$VmTag|bootstrap|DONE-joined"
        Log ('joined domain: ' + $cs.Domain)
        Disable-ScheduledTask -TaskName 'Lab-Bootstrap' -ErrorAction SilentlyContinue | Out-Null
    } else {
        Status "$VmTag|bootstrap|not-joined-yet"
        Log ('not joined: PartOfDomain=' + $cs.PartOfDomain + ' Domain=' + $cs.Domain)
    }
    return
}
Log "no action for step=$step"
