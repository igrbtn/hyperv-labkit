<#
HyperVLabKit credentials editor - a tiny local web form to manage the .env file.

Paste passwords/tokens into a browser form instead of typing secrets into a
shell or chat. Runs a loopback-only HTTP listener (127.0.0.1, random port),
opens the default browser, and on Save rewrites the .env file: comments
preserved, values quoted when needed, file ACL restricted to the current user,
atomic replace. Fields are dynamic (add/remove rows, masked by default).
Windows PowerShell 5.1 compatible, no third-party deps. ASCII only.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1 -Need HYPERV_PASS,LAB_PW
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1 -Path C:\some\.env
#>
param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) '.env'),
    [string[]]$Need = @()
)
$ErrorActionPreference = 'Stop'

$SpecialChars = ' #"''$&|;<>(){}*?!' + "`t" + '\' + '`'

function Read-EnvFile {
    param([string]$FilePath)
    $rows = New-Object System.Collections.ArrayList
    $raw  = New-Object System.Collections.ArrayList
    if (Test-Path $FilePath) {
        foreach ($line in (Get-Content $FilePath)) {
            [void]$raw.Add($line)
            $s = $line.Trim()
            if (-not $s -or $s.StartsWith('#') -or -not $line.Contains('=')) { continue }
            $pair = $line.Split('=', 2)
            $k = $pair[0].Trim()
            if ($k.ToLower().StartsWith('export ')) { $k = $k.Substring(7).Trim() }
            $v = $pair[1].Trim()
            if ($v.Length -ge 2 -and ($v[0] -eq '"' -or $v[0] -eq "'") -and $v[$v.Length - 1] -eq $v[0]) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            [void]$rows.Add(@($k, $v))
        }
    }
    return @{ rows = $rows; raw = $raw }
}

function Quote-Value {
    param([string]$Value)
    $needsQuote = ($Value -eq '')
    if (-not $needsQuote) {
        foreach ($c in $Value.ToCharArray()) {
            if ($SpecialChars.Contains([string]$c)) { $needsQuote = $true; break }
        }
    }
    if ($needsQuote) { return "'" + $Value.Replace("'", "'\''") + "'" }
    return $Value
}

function Write-EnvFile {
    # Rewrite: update known keys in place, drop removed keys, append new ones.
    # Comments and blank lines survive verbatim. Atomic replace + user-only ACL.
    param([string]$FilePath, $Rows, $RawLines)
    $wanted = @{}
    $order  = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $k = [string]$r[0]
        if ($k) { $wanted[$k] = [string]$r[1]; [void]$order.Add($k) }
    }
    $seen = @{}
    $out  = New-Object System.Collections.ArrayList
    foreach ($line in $RawLines) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#') -or -not $line.Contains('=')) { [void]$out.Add($line); continue }
        $k = $line.Split('=', 2)[0].Trim()
        if ($k.ToLower().StartsWith('export ')) { $k = $k.Substring(7).Trim() }
        if ($wanted.ContainsKey($k)) {
            [void]$out.Add($k + '=' + (Quote-Value $wanted[$k]))
            $seen[$k] = $true
        }
        # else: key removed in the form -> drop the line
    }
    $newKeys = @($order | Where-Object { -not $seen.ContainsKey($_) } | Select-Object -Unique)
    if ($newKeys.Count -gt 0) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim()) { [void]$out.Add('') }
        foreach ($k in $newKeys) { [void]$out.Add($k + '=' + (Quote-Value $wanted[$k])) }
    }
    $tmp = $FilePath + '.tmp'
    [System.IO.File]::WriteAllText($tmp, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $FilePath -Force
    # equivalent of chmod 600: strip inheritance, grant only the current user
    if (Get-Command icacls -ErrorAction SilentlyContinue) {
        icacls $FilePath /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    }
}

$Page = @'
<!doctype html><html><head><meta charset="utf-8">
<title>LabKit credentials editor</title><style>
*{box-sizing:border-box}
body{font:15px/1.5 Segoe UI,Roboto,Arial,sans-serif;background:#1f2024;color:#e6e6e6;margin:0;padding:28px}
.wrap{max-width:820px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px}.path{color:#9aa0a6;font-size:13px;margin-bottom:18px;word-break:break-all}
.row{display:flex;gap:12px;align-items:center;margin:10px 0}
.row label,.row input{font-size:15px}
.k{flex:0 0 240px}.v{flex:1}
input{background:#2e3036;border:1px solid #45474e;color:#fff;border-radius:8px;padding:10px 12px;width:100%}
input:focus{outline:none;border-color:#5a9bd4}
button{background:#3a3d44;color:#e6e6e6;border:1px solid #50535b;border-radius:8px;padding:9px 14px;cursor:pointer;font-size:14px}
button:hover{background:#45484f}
.icon{flex:0 0 auto;padding:9px 12px}
.bar{display:flex;gap:10px;align-items:center;margin-top:18px;border-top:1px solid #34363c;padding-top:16px}
.save{background:#2f6f43;border-color:#3a8a53;color:#fff;font-weight:600;margin-left:auto}
.save:hover{background:#37814f}
.status{color:#7fd1a3;font-size:14px;min-height:18px;margin-top:10px}
.hint{color:#9aa0a6;font-size:13px}
.row.need .v{border-color:#e0c060;background:#2e2c22}
.row.need .k{border-color:#e0c060}
</style></head><body><div class="wrap">
<h1>LabKit credentials editor</h1>
<div class="path">__PATH__</div>
<div id="rows"></div>
<div class="bar">
  <button onclick="addRow('','',true)">+ Add field</button>
  <label class="hint"><input type="checkbox" id="showall" style="width:auto" onchange="toggleAll()"> Show values</label>
  <button class="save" onclick="save()">Save</button>
</div>
<div class="status" id="status"></div>
</div>
<script>
const DATA = __DATA__;
const NEED = __NEED__;
function addRow(k,v,show,need){
  const wrap=document.getElementById('rows');
  const div=document.createElement('div'); div.className='row'+(need?' need':'');
  const ik=document.createElement('input'); ik.className='k'; ik.placeholder='KEY'; ik.value=k;
  const iv=document.createElement('input'); iv.className='v'; iv.placeholder=need?'paste value here':'value'; iv.value=v;
  iv.type = (show||document.getElementById('showall').checked)?'text':'password';
  const eye=document.createElement('button'); eye.className='icon'; eye.textContent='show';
  eye.onclick=()=>{iv.type=iv.type==='password'?'text':'password';};
  const del=document.createElement('button'); del.className='icon'; del.textContent='X';
  del.onclick=()=>div.remove();
  div.append(ik,iv,eye,del); wrap.append(div);
  return iv;
}
function toggleAll(){const s=document.getElementById('showall').checked;
  document.querySelectorAll('.v').forEach(i=>i.type=s?'text':'password');}
function save(){
  const rows=[...document.querySelectorAll('#rows .row')].map(r=>{
    const i=r.querySelectorAll('input'); return [i[0].value.trim(), i[1].value];
  }).filter(r=>r[0]);
  const keys=rows.map(r=>r[0]);
  if(new Set(keys).size!==keys.length){setStatus('Duplicate keys - make them unique','#e88');return;}
  fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(rows)})
    .then(r=>r.json()).then(d=>setStatus(d.ok?('Saved '+d.count+' key(s), ACL restricted to current user'):('Error: '+d.error), d.ok?'#7fd1a3':'#e88'))
    .catch(e=>setStatus('Error: '+e,'#e88'));
}
function setStatus(t,c){const s=document.getElementById('status');s.textContent=t;s.style.color=c;}
DATA.forEach(r=>addRow(r[0],r[1],false));
let firstNeed=null;
NEED.forEach(r=>{const iv=addRow(r[0],r[1],true,true); if(!firstNeed) firstNeed=iv;});
if(DATA.length===0 && NEED.length===0) addRow('','',true);
if(firstNeed){firstNeed.focus(); setStatus('Paste the value into the highlighted field, then Save','#e0c060');}
</script></body></html>
'@

function ConvertTo-RowsJson {
    param($Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return '[]' }
    $parts = foreach ($r in $Rows) {
        '[' + (ConvertTo-Json ([string]$r[0])) + ',' + (ConvertTo-Json ([string]$r[1])) + ']'
    }
    return '[' + ($parts -join ',') + ']'
}

function Send-Response {
    param($Context, [int]$Code, [string]$Body, [string]$ContentType = 'text/html; charset=utf-8')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $Code
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# --- start the loopback listener on a free port ---
$Path = [System.IO.Path]::GetFullPath($Path)
$listener = $null
$port = 0
for ($try = 0; $try -lt 20; $try++) {
    $port = Get-Random -Minimum 49300 -Maximum 64999
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    try { $l.Start(); $listener = $l; break } catch { $l.Close() }
}
if (-not $listener) { throw 'Could not bind a loopback port for the editor.' }
$url = "http://127.0.0.1:$port/"
Write-Host "Credentials editor at $url  (editing $Path)"
Write-Host 'Leave this running while you edit; Ctrl-C to stop.'
Start-Process $url | Out-Null

$rawLines = New-Object System.Collections.ArrayList
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            if ($ctx.Request.HttpMethod -eq 'GET' -and ($ctx.Request.Url.AbsolutePath -in '/', '/index.html')) {
                $env2 = Read-EnvFile -FilePath $Path
                $rawLines = $env2.raw
                $have = @{}
                foreach ($r in $env2.rows) { $have[[string]$r[0]] = $true }
                $needRows = New-Object System.Collections.ArrayList
                foreach ($k in $Need) {
                    $k = $k.Trim()
                    if ($k -and -not $have.ContainsKey($k)) { [void]$needRows.Add(@($k, '')) }
                }
                $page = $Page.Replace('__PATH__', [System.Net.WebUtility]::HtmlEncode($Path))
                $page = $page.Replace('__DATA__', (ConvertTo-RowsJson $env2.rows))
                $page = $page.Replace('__NEED__', (ConvertTo-RowsJson $needRows))
                Send-Response $ctx 200 $page
            }
            elseif ($ctx.Request.HttpMethod -eq 'POST' -and $ctx.Request.Url.AbsolutePath -eq '/save') {
                try {
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd()
                    $rows = @()
                    if ($body) { $rows = ConvertFrom-Json $body }
                    Write-EnvFile -FilePath $Path -Rows $rows -RawLines $rawLines
                    $rawLines = (Read-EnvFile -FilePath $Path).raw
                    $count = @($rows | Where-Object { $_[0] }).Count
                    Send-Response $ctx 200 ('{"ok":true,"count":' + $count + '}') 'application/json'
                } catch {
                    $err = (ConvertTo-Json ([string]$_.Exception.Message))
                    Send-Response $ctx 200 ('{"ok":false,"error":' + $err + '}') 'application/json'
                }
            }
            else {
                Send-Response $ctx 404 'not found' 'text/plain'
            }
        } catch {
            Write-Host ('request error: ' + $_.Exception.Message)
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
