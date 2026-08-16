# HyperVLabKit role: IIS web server. Local-only work - deploy with -AsSystem:
#   Install-LabGuestTask -VMName WEB01 -ScriptHostPath 'C:\Lab\mylab\role_iis.ps1' `
#     -TaskName 'Lab-Role-IIS' -User '.\Administrator' -Password '__LAB_PW__' -AsSystem
# Watch KVP until <tag>|role-iis|DONE-iis.

# --- CONFIG (edit per lab) ---
$VmTag = 'WEB01'
$Features = @('Web-Server', 'Web-Mgmt-Console', 'Web-Asp-Net45')
# --- END CONFIG ---

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $log = "$dir\role_iis.log"
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) {
    try { Set-ItemProperty -Path $kvpKey -Name 'LabStatus' -Value $s -ErrorAction SilentlyContinue } catch {}
    Log "STATUS=$s"
}

Status "$VmTag|role-iis|features"
$r = Install-WindowsFeature $Features
Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)
if ((Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running') {
    Status "$VmTag|role-iis|DONE-iis"
} else {
    Status "$VmTag|role-iis|error"
}
Disable-ScheduledTask -TaskName 'Lab-Role-IIS' -ErrorAction SilentlyContinue | Out-Null
