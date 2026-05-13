#Requires -RunAsAdministrator
# Re-points the winlogbeat Windows service at a stable config + data location,
# then removes stale versioned install dirs once the service is confirmed running.
# Idempotent: skips reconfiguration if binPath already matches the desired value;
# cleanup still runs whenever the service is healthy.
# Triggered automatically by a scheduled task on MsiInstaller event 1033,
# or runnable manually after an MSI upgrade.

[CmdletBinding()]
param(
    [switch]$KeepOldVersions  # opt out of post-success cleanup
)

$ErrorActionPreference = 'Stop'

$beats = "C:\Program Files\Elastic\Beats"
$cfg   = "$beats\winlogbeat.yml"
$data  = "$beats\data"
$logs  = "$beats\logs"

$svc = Get-Service -Name winlogbeat -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "winlogbeat service not present - nothing to do."
    exit 0
}

$newest = Get-ChildItem $beats -Directory |
          Where-Object Name -match '^\d+\.\d+\.\d+$' |
          Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $newest) { throw "No versioned Beats install dir under $beats" }

$activeVersion = [version]$newest.Name
$wlhome = Join-Path $newest.FullName "winlogbeat"
if (-not (Test-Path "$wlhome\winlogbeat.exe")) { throw "winlogbeat.exe not found at $wlhome" }
if (-not (Test-Path $cfg))                    { throw "Stable config not found at $cfg" }

$desiredBin = "`"$wlhome\winlogbeat.exe`" --environment=windows_service " +
              "-c `"$cfg`" --path.home `"$wlhome`" " +
              "--path.config `"$beats`" --path.data `"$data`" --path.logs `"$logs`" " +
              "-E logging.files.redirect_stderr=true"

# Read current binPath from registry - sc.exe qc output is locale-dependent.
$currentBin = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\winlogbeat" -Name ImagePath).ImagePath

if ($currentBin -eq $desiredBin) {
    Write-Host "winlogbeat service already correctly configured (version $activeVersion). No reconfig needed."
} else {
    Write-Host "Reconfiguring winlogbeat service:"
    Write-Host "  newest version:  $activeVersion"
    Write-Host "  current binPath: $currentBin"
    Write-Host "  desired binPath: $desiredBin"

    New-Item -ItemType Directory -Force -Path $data, $logs | Out-Null

    Stop-Service winlogbeat -ErrorAction SilentlyContinue
    & sc.exe config winlogbeat binPath= "$desiredBin" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed with exit code $LASTEXITCODE" }
    Start-Service winlogbeat
    Write-Host "winlogbeat reconfigured and started."
}

# ---------------------------------------------------------------------------
# Verify service is Running, then clean up stale version dirs.
# Cleanup only runs after a confirmed-healthy service so we never delete the
# previous install while the new one is broken.
# ---------------------------------------------------------------------------
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 500
    $svc.Refresh()
} until ($svc.Status -eq 'Running' -or (Get-Date) -gt $deadline)

if ($svc.Status -ne 'Running') {
    Write-Host "WARN: winlogbeat service did not reach Running state (current: $($svc.Status)) - skipping cleanup of old version dirs."
    exit 1
}

Write-Host "winlogbeat service is Running on version $activeVersion."

if ($KeepOldVersions) {
    Write-Host "-KeepOldVersions specified - skipping cleanup."
    exit 0
}

$stale = Get-ChildItem $beats -Directory |
         Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -ne $activeVersion }

if (-not $stale) {
    Write-Host "No stale version dirs to remove."
    exit 0
}

foreach ($d in $stale) {
    try {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "Removed stale version dir: $($d.Name)"
    } catch {
        Write-Host "WARN: Could not remove $($d.Name): $($_.Exception.Message)"
    }
}
