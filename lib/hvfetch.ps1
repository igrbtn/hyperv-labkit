# Fetch a file (or directory) FROM the Hyper-V host to the workstation.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvfetch.ps1 -Source 'C:\Lab\x.log' -Destination ./x.log
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
Import-DotEnv

$s = Get-LabSession
try {
    $dir = Split-Path $Destination -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -Path $Source -Destination $Destination -FromSession $s -Recurse -Force
    "fetched $Source -> $Destination"
} finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
