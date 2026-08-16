# HyperVLabKit common helpers: .env loading, WinRM session to the Hyper-V host,
# secret token substitution. Dot-source from entry-point scripts:
#   . "$PSScriptRoot\common.ps1"
# Windows PowerShell 5.1 compatible. ASCII only.

function Get-LabRepoRoot {
    Split-Path $PSScriptRoot -Parent
}

function Import-DotEnv {
    param([string]$Path = (Join-Path (Get-LabRepoRoot) '.env'))
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#') -or -not $s.Contains('=')) { continue }
        $pair = $s.Split('=', 2)
        $k = $pair[0].Trim()
        if ($k.ToLower().StartsWith('export ')) { $k = $k.Substring(7).Trim() }
        $v = $pair[1].Trim()
        if ($v.Length -ge 2 -and ($v[0] -eq '"' -or $v[0] -eq "'") -and $v[$v.Length - 1] -eq $v[0]) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        # An already-set process env var wins; .env only fills the gaps.
        $existing = [Environment]::GetEnvironmentVariable($k)
        if (-not $existing) { Set-Item -Path "Env:$k" -Value $v }
    }
}

function Assert-LabEnv {
    param([string[]]$Keys = @('HYPERV_HOST', 'HYPERV_USER', 'HYPERV_PASS'))
    $missing = @()
    foreach ($k in $Keys) {
        if (-not [Environment]::GetEnvironmentVariable($k)) { $missing += $k }
    }
    if ($missing.Count -gt 0) {
        throw ("Missing env vars: " + ($missing -join ', ') +
            ". Fill them with: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1 -Need " +
            ($missing -join ','))
    }
}

function Assert-LabPassword {
    # LAB_PW is embedded into single-quoted PS strings and XML inside guests:
    # forbid characters that would break out of those contexts.
    if (-not $env:LAB_PW) {
        throw ("LAB_PW is not set but the script uses the __LAB_PW__ token. " +
            "Fill it with: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1 -Need LAB_PW")
    }
    if ($env:LAB_PW -match "['`"``;<>&]") {
        throw "LAB_PW contains a forbidden character (quote, backtick, ; < > &). Allowed: letters, digits, @ # % ^ * ( ) - _ + = . ,"
    }
}

function Get-LabSession {
    Assert-LabEnv
    $sec  = ConvertTo-SecureString $env:HYPERV_PASS -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($env:HYPERV_USER, $sec)
    New-PSSession -ComputerName $env:HYPERV_HOST -Credential $cred -Authentication Negotiate
}

function Expand-LabTokens {
    # Ordinal String.Replace, NOT -replace: passwords with $ or regex chars must
    # survive verbatim. Fails hard when a token is present but its value is empty.
    param([Parameter(Mandatory)][string]$Text)
    if ($Text.Contains('__LAB_PW__')) {
        Assert-LabPassword
        $Text = $Text.Replace('__LAB_PW__', $env:LAB_PW)
    }
    return $Text
}
