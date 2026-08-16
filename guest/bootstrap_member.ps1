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
    try {
        $ifc = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        Get-NetIPAddress -InterfaceIndex $ifc.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $ifc.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $ifc.ifIndex -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $Gateway -ErrorAction SilentlyContinue | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $ifc.ifIndex -ServerAddresses $DnsServer
        Log "static IP $IP, DNS $DnsServer set"
    } catch { Log ('net cfg: ' + $_.Exception.Message) }
    try {
        # keep Windows Update from grabbing CBS during role installs
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Name 'UseWindowsUpdate' -Type DWord -Value 2 -ErrorAction SilentlyContinue
    } catch {}
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    Status "$VmTag|bootstrap|waiting-dc"
    for ($i = 0; $i -lt 60; $i++) {
        try { if (Resolve-DnsName -Name $Domain -Type A -Server $DnsServer -ErrorAction Stop) { break } } catch { Start-Sleep 10 }
    }
    # write next state BEFORE joining: Add-Computer reboots the machine
    Set-Content $stateFile 'joined'
    Status "$VmTag|bootstrap|joining"
    try {
        $sec  = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$NetBios\Administrator", $sec)
        Add-Computer -DomainName $Domain -Credential $cred -Force -Restart -ErrorAction Stop
        Log 'Add-Computer issued (reboot expected)'
    } catch {
        Log ('join ERROR: ' + $_.Exception.Message)
        Status "$VmTag|bootstrap|join-error"
        Set-Content $stateFile 'start'
    }
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
