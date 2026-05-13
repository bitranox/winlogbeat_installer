#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Winlogbeat via winget and sets up automatic post-upgrade reconfig.

.DESCRIPTION
    1. Installs (or upgrades) Elastic.Winlogbeat via winget.
    2. Copies winlogbeat.yml to C:\Program Files\Elastic\Beats\ (stable location).
    3. Copies Fix-WinlogbeatService.ps1 to the same stable location.
    4. Registers a scheduled task that re-points the winlogbeat service at the
       stable config after each MSI upgrade (triggered on MsiInstaller event 1033).
    5. Runs the reconfig script once to apply the binPath now.
    6. If the config file was (re)deployed, restarts the service so the new
       config is loaded immediately.
    7. Verifies the installation.
    8. On full success, removes old versioned install dirs (opt-out via
       -KeepOldVersions).

    Idempotent - safe to re-run.

.PARAMETER Version
    Specific Winlogbeat version to install (e.g. "9.4.1"). Defaults to latest.

.PARAMETER ForceConfigOverwrite
    Overwrite winlogbeat.yml even if one already exists at the destination.

.PARAMETER SkipWinget
    Skip the winget install/upgrade step (use when winlogbeat is already installed).

.PARAMETER KeepOldVersions
    Skip the post-success cleanup of old versioned install dirs under
    C:\Program Files\Elastic\Beats\. By default, all version dirs older than
    the currently active one are deleted after a successful verification.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$ForceConfigOverwrite,
    [switch]$SkipWinget,
    [switch]$KeepOldVersions
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$BeatsRoot   = 'C:\Program Files\Elastic\Beats'
$ConfigSrc   = Join-Path $scriptDir 'winlogbeat.yml'
$ConfigDst   = Join-Path $BeatsRoot 'winlogbeat.yml'
$ScriptSrc   = Join-Path $scriptDir 'Fix-WinlogbeatService.ps1'
$ScriptDst   = Join-Path $BeatsRoot 'Fix-WinlogbeatService.ps1'
$TaskName    = 'Fix-WinlogbeatService-OnMsiInstall'
$WingetId    = 'Elastic.Winlogbeat'

function Write-Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg){ Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "    [FAIL] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Step "Pre-flight checks"

if (-not (Test-Path $ConfigSrc)) { throw "Bundled config not found: $ConfigSrc" }
if (-not (Test-Path $ScriptSrc)) { throw "Bundled script not found: $ScriptSrc" }
Write-Ok "Bundled files present in $scriptDir"

if (-not $SkipWinget) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not installed. Install App Installer from the Microsoft Store, or pass -SkipWinget if winlogbeat is already installed."
    }
    Write-Ok "winget available"
}

# ---------------------------------------------------------------------------
# 1. Install / upgrade winlogbeat via winget
# ---------------------------------------------------------------------------
if (-not $SkipWinget) {
    Write-Step "Installing/upgrading Winlogbeat via winget"

    $wingetArgs = @(
        'install','--id', $WingetId, '--exact', '--silent',
        '--accept-source-agreements','--accept-package-agreements'
    )
    if ($Version) { $wingetArgs += @('--version', $Version) }

    & winget @wingetArgs
    $wingetExit = $LASTEXITCODE

    # winget exit codes:
    #   0                 = success
    #   -1978335189 (0x8A150027) = no applicable upgrade / already installed at requested version
    if ($wingetExit -eq 0) {
        Write-Ok "winget install completed"
    } elseif ($wingetExit -eq -1978335189) {
        Write-Ok "Winlogbeat already at requested version - no action by winget"
    } else {
        # Try upgrade path - install fails if already installed at any version
        Write-Warn2 "winget install returned $wingetExit; attempting upgrade"
        $upArgs = @('upgrade','--id', $WingetId, '--exact', '--silent',
                    '--accept-source-agreements','--accept-package-agreements')
        if ($Version) { $upArgs += @('--version', $Version) }
        & winget @upArgs
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            throw "winget upgrade also failed with exit code $LASTEXITCODE"
        }
        Write-Ok "winget upgrade path completed"
    }

    # winget upgrade fires the MSI uninstall event and the scheduled task may
    # not exist yet, so wait briefly for the service to settle.
    Start-Sleep -Seconds 3
} else {
    Write-Step "Skipping winget step (-SkipWinget)"
}

# ---------------------------------------------------------------------------
# 2. Copy stable config
# ---------------------------------------------------------------------------
Write-Step "Deploying stable config to $ConfigDst"

if (-not (Test-Path $BeatsRoot)) {
    throw "$BeatsRoot does not exist - winlogbeat install may have failed."
}

# Ensure stable data/logs dirs exist (Fix-WinlogbeatService.ps1 also creates
# them, but only on the reconfig branch - do it here unconditionally).
foreach ($d in @("$BeatsRoot\data", "$BeatsRoot\logs")) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Ok "Created $d"
    } else {
        Write-Ok "Exists:  $d"
    }
}

$configCopied = $false
if ((Test-Path $ConfigDst) -and -not $ForceConfigOverwrite) {
    Write-Warn2 "$ConfigDst already exists - leaving it untouched (use -ForceConfigOverwrite to replace)"
} else {
    if (Test-Path $ConfigDst) {
        $backup = "$ConfigDst.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $ConfigDst $backup
        Write-Warn2 "Backed up existing config to $backup"
    }
    Copy-Item $ConfigSrc $ConfigDst -Force
    $configCopied = $true
    Write-Ok "Copied winlogbeat.yml"
}

# ---------------------------------------------------------------------------
# 3. Copy maintenance script
# ---------------------------------------------------------------------------
Write-Step "Deploying maintenance script to $ScriptDst"
Copy-Item $ScriptSrc $ScriptDst -Force
Write-Ok "Copied Fix-WinlogbeatService.ps1"

# ---------------------------------------------------------------------------
# 4. Register scheduled task
# ---------------------------------------------------------------------------
Write-Step "Registering scheduled task '$TaskName'"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDst`""

$cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $cls -ClientOnly
$trigger.Enabled = $true
$trigger.Subscription = @'
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='MsiInstaller'] and EventID=1033]]</Select>
  </Query>
</QueryList>
'@
$trigger.Delay = 'PT30S'

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName `
    -Description "Re-points the winlogbeat service at the newest installed Beats version after MSI upgrades." `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
Write-Ok "Scheduled task registered"

# ---------------------------------------------------------------------------
# 5. Apply config now (run script once)
# ---------------------------------------------------------------------------
Write-Step "Running reconfig script once to apply binPath"
$reconfigArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptDst)
if ($KeepOldVersions) { $reconfigArgs += '-KeepOldVersions' }
& powershell.exe @reconfigArgs
if ($LASTEXITCODE -ne 0) { throw "Reconfig script exited with code $LASTEXITCODE" }
Write-Ok "Reconfig script ran successfully"

# ---------------------------------------------------------------------------
# 5b. Restart service if config was just (re)deployed
# ---------------------------------------------------------------------------
# The maintenance script only restarts the service when binPath needs to
# change. If we just overwrote winlogbeat.yml but binPath was already
# correct, the running service still holds the old config in memory - so
# force a restart to pick up the new bytes.
if ($configCopied) {
    Write-Step "Restarting winlogbeat to load fresh config"
    Restart-Service winlogbeat
    Start-Sleep -Seconds 2
    Write-Ok "Service restarted"
}

# ---------------------------------------------------------------------------
# 6. Verification
# ---------------------------------------------------------------------------
Write-Step "Verifying installation"

$failures = 0

# Files in place
foreach ($f in @($ConfigDst, $ScriptDst)) {
    if (Test-Path $f) { Write-Ok "Exists: $f" } else { Write-Fail "Missing: $f"; $failures++ }
}

# Service exists and running
$svc = Get-Service -Name winlogbeat -ErrorAction SilentlyContinue
if (-not $svc)                  { Write-Fail "winlogbeat service is not registered"; $failures++ }
elseif ($svc.Status -ne 'Running') { Write-Fail "winlogbeat service is $($svc.Status), expected Running"; $failures++ }
else                            { Write-Ok "winlogbeat service is Running" }

# binPath references stable config
if ($svc) {
    $imagePath = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\winlogbeat" -Name ImagePath).ImagePath
    $expectedFragment = "-c `"$ConfigDst`""
    if ($imagePath -like "*$expectedFragment*") {
        Write-Ok "Service binPath references stable config"
    } else {
        Write-Fail "Service binPath does NOT reference stable config"
        Write-Host "      actual: $imagePath" -ForegroundColor DarkGray
        $failures++
    }
}

# Scheduled task registered and ready
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task)             { Write-Fail "Scheduled task '$TaskName' not registered"; $failures++ }
elseif ($task.State -notin 'Ready','Running') { Write-Fail "Scheduled task state is $($task.State)"; $failures++ }
else                        { Write-Ok "Scheduled task is in state '$($task.State)'" }

# Last task run result (only if task has actually run; 267011 = SCHED_S_TASK_HAS_NOT_RUN)
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
if ($taskInfo -and $taskInfo.LastTaskResult -ne 267011 -and $taskInfo.LastRunTime.Year -gt 2000) {
    if ($taskInfo.LastTaskResult -eq 0) {
        Write-Ok "Last task result: 0 (success) at $($taskInfo.LastRunTime)"
    } else {
        Write-Warn2 "Last task result: $($taskInfo.LastTaskResult) at $($taskInfo.LastRunTime)"
    }
}

# ---------------------------------------------------------------------------
# 7. Cleanup of old version dirs (only on full success)
# ---------------------------------------------------------------------------
if ($failures -eq 0 -and -not $KeepOldVersions) {
    Write-Step "Cleaning up old version dirs under $BeatsRoot"

    # Active version = the one referenced by the service binPath we just verified.
    $imagePath = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\winlogbeat" -Name ImagePath).ImagePath
    $activeVersion = $null
    if ($imagePath -match 'Elastic\\Beats\\(\d+\.\d+\.\d+)\\winlogbeat') {
        $activeVersion = [version]$matches[1]
    }
    if (-not $activeVersion) {
        Write-Warn2 "Could not determine active version from binPath - skipping cleanup"
    } else {
        $stale = Get-ChildItem $BeatsRoot -Directory |
                 Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -ne $activeVersion }
        if (-not $stale) {
            Write-Ok "No old version dirs to remove (active: $activeVersion)"
        } else {
            foreach ($d in $stale) {
                try {
                    Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop
                    Write-Ok "Removed $($d.Name)"
                } catch {
                    Write-Warn2 "Could not remove $($d.Name): $($_.Exception.Message)"
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
if ($failures -eq 0) {
    Write-Host "==> Installation complete. All checks passed." -ForegroundColor Green
    Write-Host ""
    Write-Host "Future Winlogbeat upgrades (e.g. 'winget upgrade --id $WingetId') will"
    Write-Host "automatically re-point the service at the stable config within ~30s of"
    Write-Host "the install completing. No manual action required."
    exit 0
} else {
    Write-Host "==> Installation finished with $failures failed check(s)." -ForegroundColor Red
    exit 1
}
