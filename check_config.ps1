# Validates a winlogbeat config by invoking the bundled winlogbeat.exe
# ('test config' and, by default, 'test output').
#
# Defaults to the deployed stable config at
#   C:\Program Files\Elastic\Beats\winlogbeat.yml
# Pass -ConfigPath <path> to check a different file (e.g. the bundled copy
# next to this script before deploying it).
#
# Does NOT require administrator rights - the test commands are read-only
# and use a private temp data dir, so they never disturb the running service.
#
# Exits 0 if all checks pass, 1 otherwise.

[CmdletBinding()]
param(
    [string]$ConfigPath,        # defaults to deployed stable config
    [switch]$SkipOutputTest,    # skip 'test output' (avoids contacting Graylog)
    [switch]$Bundled            # convenience: use winlogbeat.yml next to this script
)

$ErrorActionPreference = 'Stop'

$beats = "C:\Program Files\Elastic\Beats"

# -- 1. Resolve the config path -------------------------------------------------
if ($Bundled) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $cfg = Join-Path $scriptDir 'winlogbeat.yml'
} elseif ($ConfigPath) {
    $cfg = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
} else {
    $cfg = Join-Path $beats 'winlogbeat.yml'
}

if (-not (Test-Path -LiteralPath $cfg)) {
    Write-Host "Config not found: $cfg" -ForegroundColor Red
    exit 1
}
Write-Host "Config under test: $cfg"

# -- 2. Locate winlogbeat.exe (newest versioned install dir) --------------------
if (-not (Test-Path -LiteralPath $beats)) {
    Write-Host "Beats install root not found: $beats" -ForegroundColor Red
    Write-Host "Run install.ps1 (or 'winget install Elastic.Winlogbeat') first." -ForegroundColor Red
    exit 1
}

$newest = Get-ChildItem $beats -Directory -ErrorAction SilentlyContinue |
          Where-Object Name -match '^\d+\.\d+\.\d+$' |
          Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $newest) {
    Write-Host "No versioned Beats install dir under $beats" -ForegroundColor Red
    exit 1
}

$wlhome = Join-Path $newest.FullName 'winlogbeat'
$exe    = Join-Path $wlhome 'winlogbeat.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "winlogbeat.exe not found at $exe" -ForegroundColor Red
    exit 1
}
Write-Host "Using binary:      $exe (version $($newest.Name))"

# -- 3. Use a private temp data dir so we never touch the live registry ---------
$tmpData = Join-Path $env:TEMP "winlogbeat-check-$PID"
$tmpLogs = Join-Path $env:TEMP "winlogbeat-check-$PID-logs"
New-Item -ItemType Directory -Force -Path $tmpData, $tmpLogs | Out-Null

$commonArgs = @(
    '-c', $cfg,
    '--path.home',   $wlhome,
    '--path.config', $beats,
    '--path.data',   $tmpData,
    '--path.logs',   $tmpLogs
)

$failures = 0

try {
    # -- 4. test config ---------------------------------------------------------
    Write-Host ""
    Write-Host "==> winlogbeat test config" -ForegroundColor Cyan
    & $exe test config @commonArgs
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        Write-Host "    [OK]   config syntax valid" -ForegroundColor Green
    } else {
        Write-Host "    [FAIL] test config exited with code $rc" -ForegroundColor Red
        $failures++
    }

    # -- 5. test output (optional) ---------------------------------------------
    if (-not $SkipOutputTest) {
        Write-Host ""
        Write-Host "==> winlogbeat test output" -ForegroundColor Cyan
        & $exe test output @commonArgs
        $rc = $LASTEXITCODE
        if ($rc -eq 0) {
            Write-Host "    [OK]   output reachable" -ForegroundColor Green
        } else {
            Write-Host "    [FAIL] test output exited with code $rc" -ForegroundColor Red
            $failures++
        }
    } else {
        Write-Host ""
        Write-Host "==> Skipping test output (-SkipOutputTest)" -ForegroundColor DarkGray
    }
}
finally {
    # -- 6. Clean up temp dirs --------------------------------------------------
    Remove-Item -LiteralPath $tmpData, $tmpLogs -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
