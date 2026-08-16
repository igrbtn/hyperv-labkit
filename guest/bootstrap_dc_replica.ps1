# HyperVLabKit guest bootstrap: ADDITIONAL domain controller (existing forest),
# optionally into a specific AD site. IMPORTANT: the AD site must exist BEFORE
# this VM promotes (create sites/subnets on the first DC right after the forest
# is up - see the lab-ad-multisite skill).
# Copy into labs/<lab>/guest/, edit CONFIG, stage on host, pass to New-LabVM.

# --- CONFIG (edit per lab) ---
$VmTag     = 'DC02'
$IP        = '10.80.1.10'
$Prefix    = 24
$Gateway   = '10.80.0.1'
$DnsServer = '10.80.0.10'    # first DC
$Domain    = 'research.lab'
$NetBios   = 'RESEARCH'
$SiteName  = 'Site-B'        # '' = Default-First-Site-Name
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
    # hard gate: promoting a DC without a NIC cannot work
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
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    Status "$VmTag|bootstrap|waiting-dc"
    for ($i = 0; $i -lt 60; $i++) {
        try { if (Resolve-DnsName -Name $Domain -Type A -Server $DnsServer -ErrorAction Stop) { break } } catch { Start-Sleep 10 }
    }
    Status "$VmTag|bootstrap|features"
    $r = Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
    Log ('features success=' + $r.Success)
    Set-Content $stateFile 'promote'
    Status "$VmTag|bootstrap|promoting"
    try {
        Import-Module ADDSDeployment
        $sec  = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$NetBios\Administrator", $sec)
        $dsrm = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        $p = @{
            DomainName                    = $Domain
            Credential                    = $cred
            InstallDns                    = $true
            SafeModeAdministratorPassword = $dsrm
            NoRebootOnCompletion          = $false
            Force                         = $true
        }
        if ($SiteName) { $p.SiteName = $SiteName }
        Install-ADDSDomainController @p
        Log 'Install-ADDSDomainController returned (reboot pending)'
    } catch {
        Log ('promote ERROR: ' + $_.Exception.Message)
        Status "$VmTag|bootstrap|promote-error"
        Set-Content $stateFile 'start'
    }
    return
}

if ($step -eq 'promote') {
    Status "$VmTag|bootstrap|verify"
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $dc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
            if ($dc) { $ok = $true; break }
        } catch { Start-Sleep 20 }
    }
    if ($ok) {
        Set-Content $stateFile 'done'
        Status "$VmTag|bootstrap|DONE-dc"
        Disable-ScheduledTask -TaskName 'Lab-Bootstrap' -ErrorAction SilentlyContinue | Out-Null
    } else {
        Status "$VmTag|bootstrap|adws-not-ready"
    }
    return
}
Log "no action for step=$step"
