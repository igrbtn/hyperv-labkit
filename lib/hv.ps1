<#
Run a PowerShell script ON the Hyper-V host over WinRM.

host/blocks.ps1 is prepended to the submitted script, so lab scripts can call
New-LabVM, Install-LabGuestTask, Get-LabKvpStatus etc. directly. The __LAB_PW__
token is replaced with $env:LAB_PW (loaded from .env) before anything goes over
the wire - no password literals on disk.

Usage (from the repo root):
  powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/status.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/mylab/build.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/screenshot.ps1 -ArgumentList DC01

Note: because blocks.ps1 is prepended, the submitted script must not declare a
param() block; positional arguments are available as $args.
#>
param(
    [Parameter(Mandatory)][string]$File,
    [object[]]$ArgumentList = @()
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
Import-DotEnv

$root   = Get-LabRepoRoot
$blocks = Get-Content (Join-Path $root 'host\blocks.ps1') -Raw
$body   = Get-Content $File -Raw -ErrorAction Stop
$script = Expand-LabTokens ($blocks + "`n" + $body)

$s = Get-LabSession
try {
    $remoteErr = @()
    Invoke-Command -Session $s -ScriptBlock ([scriptblock]::Create($script)) `
        -ArgumentList $ArgumentList -ErrorAction Continue -ErrorVariable remoteErr
    if ($remoteErr.Count -gt 0) {
        foreach ($e in $remoteErr) { Write-Host ("ERR: " + $e) -ForegroundColor Red }
        exit 1
    }
} finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
