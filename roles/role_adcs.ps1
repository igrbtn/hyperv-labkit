# HyperVLabKit role: Enterprise Root CA on a DOMAIN-JOINED guest.
# Deploy via Install-LabGuestTask with a DOMAIN ADMIN account (Enterprise CA
# setup needs Enterprise Admins rights - do NOT use -AsSystem):
#   Install-LabGuestTask -VMName CA01 -ScriptHostPath 'C:\Lab\mylab\role_adcs.ps1' `
#     -TaskName 'Lab-Role-ADCS' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
# Watch KVP until <tag>|role-adcs|DONE-adcs.

# --- CONFIG (edit per lab) ---
$VmTag  = 'CA01'
$CaName = 'Research-Root-CA'
# --- END CONFIG ---

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $log = "$dir\role_adcs.log"
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) {
    try { Set-ItemProperty -Path $kvpKey -Name 'LabStatus' -Value $s -ErrorAction SilentlyContinue } catch {}
    Log "STATUS=$s"
}

if (Get-Service CertSvc -ErrorAction SilentlyContinue) {
    Status "$VmTag|role-adcs|DONE-adcs"
    Disable-ScheduledTask -TaskName 'Lab-Role-ADCS' -ErrorAction SilentlyContinue | Out-Null
    return
}
Status "$VmTag|role-adcs|features"
try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null
Status "$VmTag|role-adcs|install"
try {
    Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CACommonName $CaName -Force -ErrorAction Stop | Out-Null
    $svc = Get-Service CertSvc
    Log ('CertSvc: ' + $svc.Status)
    Status "$VmTag|role-adcs|DONE-adcs"
} catch {
    Log ('adcs ERROR: ' + $_.Exception.Message)
    Status "$VmTag|role-adcs|error"
}
Disable-ScheduledTask -TaskName 'Lab-Role-ADCS' -ErrorAction SilentlyContinue | Out-Null

# NOTE (see docs/GOTCHAS.md): the default WebServer template does not grant
# Enroll to ordinary computers/users. For certreq enrollment grant Enroll on
# the template (extended-right GUID 0e10c968-78fb-11d2-90d4-00c04f79dc55) or
# enroll as an Enterprise Admin.
