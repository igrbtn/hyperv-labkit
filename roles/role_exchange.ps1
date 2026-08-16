# HyperVLabKit role: Exchange 2019 Mailbox on a DOMAIN-JOINED WS2022 guest.
# IMPORTANT: Exchange 2019 is NOT supported on WS2025 guests - build the VM
# with -OsVersion 2022. Attach the Exchange ISO as a DVD BEFORE deploying:
#   Add-VMDvdDrive -VMName EXCH01 -Path '<iso>' (host side)
#   Set-VMFirmware -VMName EXCH01 -FirstBootDevice (Get-VMHardDiskDrive -VMName EXCH01)
# Deploy via Install-LabGuestTask as a DOMAIN ADMIN (schema/AD prep rights):
#   Install-LabGuestTask -VMName EXCH01 -ScriptHostPath 'C:\Lab\mylab\role_exchange.ps1' `
#     -TaskName 'Lab-Role-Exchange' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
# State machine (survives reboots): features -> reboot -> prereqs -> reboot ->
# prepinstall -> DONE. Full install takes 30+ minutes; poll KVP every 5 min.
# Read docs/GOTCHAS.md (RebootPending, UCMA, watermark, arbitration mailboxes)
# BEFORE debugging a failed install.

# --- CONFIG (edit per lab) ---
$VmTag   = 'EXCH01'
$OrgName = 'ResearchLab'
# --- END CONFIG ---

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'
$state = "$dir\exch-state.txt"
$log = "$dir\role_exchange.log"
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) {
    try { Set-ItemProperty -Path $kvpKey -Name 'LabStatus' -Value $s -ErrorAction SilentlyContinue } catch {}
    Log "STATUS=$s"
}
function Find-Setup {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Name) {
        if (Test-Path "${d}:\Setup.exe" -PathType Leaf) { return "${d}:" }
    }
    return $null
}
$step = if (Test-Path $state) { (Get-Content $state -Raw).Trim() } else { 'features' }
Log "=== fired, step=$step ==="

if ($step -eq 'features') {
    Status "$VmTag|role-exch|features"
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    $feats = @(
        'Server-Media-Foundation', 'NET-Framework-45-Features', 'RPC-over-HTTP-proxy',
        'RSAT-Clustering', 'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-Mgmt', 'RSAT-Clustering-PowerShell',
        'WAS-Process-Model', 'Web-Asp-Net45', 'Web-Basic-Auth', 'Web-Client-Auth', 'Web-Digest-Auth',
        'Web-Dir-Browsing', 'Web-Dyn-Compression', 'Web-Http-Errors', 'Web-Http-Logging', 'Web-Http-Redirect',
        'Web-Http-Tracing', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter', 'Web-Lgcy-Mgmt-Console', 'Web-Metabase',
        'Web-Mgmt-Console', 'Web-Mgmt-Service', 'Web-Net-Ext45', 'Web-Request-Monitor', 'Web-Server',
        'Web-Stat-Compression', 'Web-Static-Content', 'Web-Windows-Auth', 'Web-WMI',
        'Windows-Identity-Foundation', 'RSAT-ADDS'
    )
    $r = Install-WindowsFeature $feats
    Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)
    Set-Content $state 'prereqs'
    Status "$VmTag|role-exch|features-done-reboot"
    Restart-Computer -Force
    return
}

if ($step -eq 'prereqs') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $pre = "$dir\exch-prereqs"
    New-Item -ItemType Directory -Force -Path $pre | Out-Null
    $dvd = Find-Setup
    Log "prereqs dvd=$dvd"

    Status "$VmTag|role-exch|ucma"
    # SpeechPlatformRuntime is a UCMA dependency; install it first
    $spr = Join-Path $dvd 'UCMARedist\Chains\SpeechPlatformRuntime.msi'
    if (Test-Path $spr) {
        Start-Process msiexec.exe -ArgumentList '/i', "`"$spr`"", '/qn', '/norestart' -Wait -ErrorAction SilentlyContinue
        Log 'SpeechPlatformRuntime installed'
    }
    # UcmaRuntime.msi has a LaunchCondition (blocks direct msiexec); must go via
    # bootstrapper Setup.exe which spawns children and returns immediately ->
    # poll the Uninstall registry until the Core Runtime shows up
    $ucma = Join-Path $dvd 'UCMARedist\Setup.exe'
    if (Test-Path $ucma) {
        Start-Process $ucma -ArgumentList '/passive', '/norestart'
        $ok = $false
        $ukeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep 10
            if (Get-ItemProperty $ukeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Unified Communications Managed API 4.0.*Core Runtime' }) { $ok = $true; break }
        }
        Log ('UCMA Core Runtime registered=' + $ok)
    } else { Log "UCMA Setup.exe not found at $ucma" }

    Status "$VmTag|role-exch|vcredist"
    # unpinned Microsoft URLs, no checksums upstream - documented risk; needs NAT internet
    $vcs = @(
        @{ n = 'vc2012.exe'; u = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe' },
        @{ n = 'vc2013.exe'; u = 'https://aka.ms/highdpimfc2013x64enu' }
    )
    foreach ($vc in $vcs) {
        $dst = Join-Path $pre $vc.n
        try {
            if (-not (Test-Path $dst)) { Invoke-WebRequest -Uri $vc.u -OutFile $dst -UseBasicParsing -TimeoutSec 120 }
            Start-Process $dst -ArgumentList '/install', '/quiet', '/norestart' -Wait -ErrorAction SilentlyContinue
            Log ('installed ' + $vc.n)
        } catch { Log ('vcredist ' + $vc.n + ' err: ' + $_.Exception.Message) }
    }

    Status "$VmTag|role-exch|urlrewrite"
    $rw = Join-Path $pre 'rewrite.msi'
    try {
        if (-not (Test-Path $rw)) { Invoke-WebRequest -Uri 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' -OutFile $rw -UseBasicParsing -TimeoutSec 120 }
        Start-Process msiexec.exe -ArgumentList '/i', $rw, '/quiet', '/norestart' -Wait -ErrorAction SilentlyContinue
        Log 'URL Rewrite installed'
    } catch { Log ('urlrewrite err: ' + $_.Exception.Message) }

    # prereq installers set a pending-reboot flag; MUST reboot before Setup's
    # prereq check or ALL prep steps fail with Rule:RebootPending
    Set-Content $state 'prepinstall'
    Status "$VmTag|role-exch|prereqs-done-reboot"
    Restart-Computer -Force
    return
}

if ($step -eq 'prepinstall') {
    $dvd = Find-Setup
    $setup = if ($dvd) { "$dvd\Setup.exe" } else { $null }
    Log "prepinstall setup=$setup"
    if (-not $setup) { Status "$VmTag|role-exch|no-setup-media"; return }

    # clear any MailboxRole watermark from a prior partial install so Setup
    # does a fresh install instead of trying to resume
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match 'Role$' } |
        ForEach-Object { Remove-ItemProperty -Path $_.PSPath -Name 'Watermark', 'Action' -ErrorAction SilentlyContinue }

    $accept = '/IAcceptExchangeServerLicenseTerms_DiagnosticDataON'
    Status "$VmTag|role-exch|prepare-ad"
    $p1 = Start-Process $setup -ArgumentList $accept, '/PrepareSchema' -Wait -PassThru -NoNewWindow
    Log ('PrepareSchema exit=' + $p1.ExitCode)
    $p2 = Start-Process $setup -ArgumentList $accept, '/PrepareAD', "/OrganizationName:$OrgName" -Wait -PassThru -NoNewWindow
    Log ('PrepareAD exit=' + $p2.ExitCode)
    $p3 = Start-Process $setup -ArgumentList $accept, '/PrepareAllDomains' -Wait -PassThru -NoNewWindow
    Log ('PrepareAllDomains exit=' + $p3.ExitCode)

    Status "$VmTag|role-exch|install"
    $p4 = Start-Process $setup -ArgumentList $accept, '/Mode:Install', '/Roles:Mailbox' -Wait -PassThru -NoNewWindow
    Log ('Install exit=' + $p4.ExitCode)
    if ($p4.ExitCode -eq 0) { Status "$VmTag|role-exch|DONE-install" } else { Status "$VmTag|role-exch|install-exit-$($p4.ExitCode)" }
    Set-Content $state 'done'
    Disable-ScheduledTask -TaskName 'Lab-Role-Exchange' -ErrorAction SilentlyContinue | Out-Null
    return
}
Log "no action for step=$step"
