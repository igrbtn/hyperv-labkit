# HyperVLabKit guest bootstrap: FIRST domain controller (new forest).
# Copy into labs/<lab>/guest/, edit the CONFIG block, stage on the host with
# lib/hvcopy.ps1, then pass the host path to New-LabVM -BootstrapHostPath.
# Runs as scheduled task 'Lab-Bootstrap' (SYSTEM), survives reboots via
# C:\Lab\state.txt. The __LAB_PW__ token is baked in at build time.

# --- CONFIG (edit per lab) ---
$VmTag   = 'DC01'          # short tag used in LabStatus values
$IP      = '10.80.0.10'
$Prefix  = 24
$Gateway = '10.80.0.1'
$Domain  = 'research.lab'
$NetBios = 'RESEARCH'
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
    # Hard gate: promoting a forest without a working NIC produces a broken
    # domain that is faster to rebuild than to repair. No adapter -> stop and
    # let the repeating task trigger try again.
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
        Set-DnsClientServerAddress -InterfaceIndex $ifc.ifIndex -ServerAddresses 127.0.0.1
        Log "static IP $IP set on $($ifc.Name)"
    } catch {
        Log ('net cfg ERROR: ' + $_.Exception.Message)
        Status "$VmTag|bootstrap|net-error"
        return
    }
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    Status "$VmTag|bootstrap|features"
    $r = Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
    Log ('features success=' + $r.Success)
    # write next state BEFORE promoting: Install-ADDSForest reboots the machine
    Set-Content $stateFile 'promote'
    Status "$VmTag|bootstrap|promoting"
    try {
        Import-Module ADDSDeployment
        $dsrm = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        Install-ADDSForest -DomainName $Domain -DomainNetbiosName $NetBios `
            -ForestMode 'WinThreshold' -DomainMode 'WinThreshold' -InstallDns:$true `
            -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion:$false -Force:$true
        Log 'Install-ADDSForest returned (reboot pending)'
    } catch {
        Log ('promote ERROR: ' + $_.Exception.Message)
        Status "$VmTag|bootstrap|promote-error"
        Set-Content $stateFile 'start'
    }
    return
}

if ($step -eq 'promote') {
    # after the promo reboot: wait for AD web services, then verify the forest
    Status "$VmTag|bootstrap|verify"
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $d = Get-ADDomain -ErrorAction Stop
            if ($d.DNSRoot -eq $Domain) { $ok = $true; break }
        } catch { Start-Sleep 20 }
    }
    if ($ok) {
        Set-Content $stateFile 'done'
        Status "$VmTag|bootstrap|DONE-forest"
        Disable-ScheduledTask -TaskName 'Lab-Bootstrap' -ErrorAction SilentlyContinue | Out-Null
    } else {
        Status "$VmTag|bootstrap|adws-not-ready"
        Log 'AD not answering yet; will retry on next boot/trigger'
    }
    return
}
Log "no action for step=$step"
