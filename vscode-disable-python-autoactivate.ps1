<#
.SYNOPSIS
  Stop VS Code from prepending a Python-env activation (e.g. `source activate` /
  `conda activate`) to every new integrated terminal.

.DESCRIPTION
  Writes the relevant keys into your LOCAL VS Code *User* settings.json. Those
  apply to remote/devcontainer sessions too (they flow from your machine into
  the container) and, living on your machine, survive any container rebuild —
  which the container-side "Remote" settings do not. Run this ON THE PC where
  you run VS Code (the Windows side for a container attached from Windows).

  Idempotent: it looks for each key and adds only the ones that are missing,
  leaving the rest of the file (comments included) untouched. A timestamped
  backup is written before any edit.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File vscode-disable-python-autoactivate.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File vscode-disable-python-autoactivate.ps1 -Insiders
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File vscode-disable-python-autoactivate.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch] $Insiders,
    [string] $Path,
    [switch] $Check
)
$ErrorActionPreference = 'Stop'

# key => json-value. Add an entry to enforce another setting the same way.
# python-envs.terminal.autoActivationType = current Python extension setting;
# python.terminal.activateEnvironment      = legacy key, still honoured.
$Settings = [ordered]@{
    'python-envs.terminal.autoActivationType' = '"off"'
    'python.terminal.activateEnvironment'     = 'false'
}

function Write-Ok($t)   { Write-Host "  OK   $t" -ForegroundColor Green }
function Write-Info($t) { Write-Host "  $t" }
function Write-Warn2($t){ Write-Host "  WARN $t" -ForegroundColor Yellow }

# --- locate the User settings.json -------------------------------------------
$flavor = if ($Insiders) { 'Code - Insiders' } else { 'Code' }
if (-not $Path) {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $Path = Join-Path $env:APPDATA "$flavor\User\settings.json"
    } elseif ($IsMacOS) {
        $Path = Join-Path $HOME "Library/Application Support/$flavor/User/settings.json"
    } else {
        $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $Path = Join-Path $base "$flavor/User/settings.json"
    }
}
Write-Info "settings file: $Path"

$raw = if (Test-Path $Path) { Get-Content -Raw -Path $Path } else { '' }

# --- which keys are missing? -------------------------------------------------
$missing = [ordered]@{}
foreach ($key in $Settings.Keys) {
    if ($raw -match [regex]::Escape('"' + $key + '"')) {
        Write-Ok "already set: $key (left as-is)"
    } else {
        $missing[$key] = $Settings[$key]
        Write-Info "missing: $key"
    }
}

if ($missing.Count -eq 0) { Write-Ok 'nothing to do — all keys already present'; exit 0 }
if ($Check) { Write-Warn2 "$($missing.Count) key(s) missing (run without -Check to add them)"; exit 0 }

# --- build the block (trailing comma: settings.json is JSONC) ----------------
$ins = ($missing.GetEnumerator() | ForEach-Object { "    `"$($_.Key)`": $($_.Value)," }) -join "`n"

$dir = Split-Path -Parent $Path
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM
if (-not ($raw -match '\{')) {
    # Fresh / objectless file: write a clean object.
    [IO.File]::WriteAllText($Path, "{`n$ins`n}`n", $utf8)
    Write-Ok "created $Path with $($missing.Count) key(s)"
} else {
    $bak = "$Path.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -Path $Path -Destination $bak
    # Insert right after the first '{'; everything else stays byte-for-byte.
    $p = $raw.IndexOf('{')
    $out = $raw.Substring(0, $p + 1) + "`n" + $ins + $raw.Substring($p + 1)
    [IO.File]::WriteAllText($Path, $out, $utf8)
    Write-Ok "added $($missing.Count) key(s) (backup: $bak)"
}

# --- verify ------------------------------------------------------------------
$after = Get-Content -Raw -Path $Path
$fail = $false
foreach ($key in $Settings.Keys) {
    if ($after -notmatch [regex]::Escape('"' + $key + '"')) { Write-Warn2 "still missing after write: $key"; $fail = $true }
}
if (-not $fail) { Write-Ok 'done — reopen a terminal in VS Code; no activation line should appear' }
exit ([int]$fail)
