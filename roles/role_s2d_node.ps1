# HyperVLabKit role: S2D cluster node prep - clustering features + reboot.
# Deploy into a DOMAIN-JOINED node via Install-LabGuestTask:
#   Install-LabGuestTask -VMName S2D1 -ScriptHostPath 'C:\Lab\mylab\role_s2d_node.ps1' `
#     -TaskName 'Lab-Role-S2DNode' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
# State machine survives the reboot. Watch KVP until <tag>|role-s2dnode|DONE-s2dnode.
# Cluster formation itself (New-Cluster, Enable-ClusterStorageSpacesDirect) runs
# AFTER all nodes report DONE - see the lab-s2d-stretched skill.

# --- CONFIG (edit per lab) ---
$VmTag    = 'S2D1'
$Features = @('Failover-Clustering', 'FS-FileServer', 'RSAT-Clustering-PowerShell')
$WithHyperV = $false   # $true for hyper-converged labs (needs -EnableNestedVirt VM)
# --- END CONFIG ---

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $stateFile = "$dir\s2dnode-state.txt"; $log = "$dir\role_s2d_node.log"
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) {
    try { Set-ItemProperty -Path $kvpKey -Name 'LabStatus' -Value $s -ErrorAction SilentlyContinue } catch {}
    Log "STATUS=$s"
}
$step = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { 'features' }
Log "=== fired, step=$step ==="

if ($step -eq 'features') {
    Status "$VmTag|role-s2dnode|features"
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    $feats = $Features
    if ($WithHyperV) { $feats = $feats + @('Hyper-V', 'Hyper-V-PowerShell') }
    $r = Install-WindowsFeature $feats -IncludeManagementTools
    Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)
    # write next state BEFORE rebooting
    Set-Content $stateFile 'verify'
    Status "$VmTag|role-s2dnode|features-done-reboot"
    Restart-Computer -Force
    return
}

if ($step -eq 'verify') {
    Status "$VmTag|role-s2dnode|verify"
    $clus = Get-WindowsFeature Failover-Clustering
    if ($clus.Installed) {
        Set-Content $stateFile 'done'
        Status "$VmTag|role-s2dnode|DONE-s2dnode"
        Disable-ScheduledTask -TaskName 'Lab-Role-S2DNode' -ErrorAction SilentlyContinue | Out-Null
    } else {
        Log 'Failover-Clustering not installed; rewinding to features'
        Set-Content $stateFile 'features'
        Status "$VmTag|role-s2dnode|retry-features"
    }
    return
}
Log "no action for step=$step"
