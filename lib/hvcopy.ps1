# Copy a local file (or directory) TO the Hyper-V host.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source guest.ps1 -Destination 'C:\Lab\guest.ps1'
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
    if ($dir) {
        Invoke-Command -Session $s -ScriptBlock {
            param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null
        } -ArgumentList $dir
    }
    Copy-Item -Path $Source -Destination $Destination -ToSession $s -Recurse -Force
    "copied $Source -> $Destination"
} finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
