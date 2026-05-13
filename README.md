# Winlogbeat Installer

Self-contained installer for Elastic Winlogbeat on Windows that **eliminates
the need to manually copy `winlogbeat.yml` after every MSI upgrade**.

## What it does

1. Installs (or upgrades) **Winlogbeat** via `winget` (`Elastic.Winlogbeat`).
2. Deploys `winlogbeat.yml` to a **stable location** outside the versioned
   install dir: `C:\Program Files\Elastic\Beats\winlogbeat.yml`.
   **Existing configs are preserved** by default - see
   [Config file behavior](#config-file-winlogbeatyml-behavior) below.
3. Deploys the maintenance script `Fix-WinlogbeatService.ps1` next to it.
4. Registers a **scheduled task** that fires whenever the MSI installer
   reports a successful product install (Application log, source `MsiInstaller`,
   event ID `1033`). The task re-points the service's `binPath` at the stable
   config and the newest installed version dir.
5. Runs the maintenance script once to apply the binPath immediately.
6. If the config file was just (re)deployed, restarts the service so the
   new config is loaded into the running process.
7. Verifies everything is wired up.
8. On full success, deletes old versioned install dirs under
   `C:\Program Files\Elastic\Beats\` (opt-out via `-KeepOldVersions`).

## Why

The Elastic Winlogbeat MSI installs into versioned dirs
(`C:\Program Files\Elastic\Beats\<ver>\winlogbeat\`) and re-registers the
`winlogbeat` Windows service with all paths pointing into that versioned dir
on every upgrade. Out of the box that means you must copy `winlogbeat.yml`
into the new dir after every upgrade or the service won't find its config.

This installer breaks that cycle by:

- Keeping the config (and `data/`, `logs/`) at a path that never changes.
- Auto-reapplying the service `binPath` after each MSI upgrade.

## Requirements

- **Windows** with **PowerShell** (5.1+; the installer uses cmdlets present
  in both Windows PowerShell and PowerShell 7).
- **`winget`** (App Installer) - shipped with current Windows 10/11.
- **Elevation required.** All steps need administrator rights. Both scripts
  start with `#Requires -RunAsAdministrator`; PowerShell refuses to run them
  in a non-elevated session with a clear error message.

## Files in this directory

| File                        | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                    |
|-----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `install.ps1`               | The installer / orchestrator. Run elevated.                                                                                                                                                                                                                                                                                                                                                                                |
| `winlogbeat.yml`            | **Sample** seed config tailored for **Graylog** (Beats input on port 5044, TLS off) and **Windows 11**. Adjust the `output.logstash.hosts` target and event log selection for your environment. Copied to `C:\Program Files\Elastic\Beats\winlogbeat.yml` only on fresh installs (or with `-ForceConfigOverwrite`). To change shipper behavior on a machine that already has it deployed, edit the deployed copy directly. |
| `Fix-WinlogbeatService.ps1` | Idempotent maintenance script that re-points the service. Deployed alongside the config.                                                                                                                                                                                                                                                                                                                                   |
| `check_config.ps1`          | Standalone validator. Runs `winlogbeat.exe test config` (and `test output`) against the deployed config — or a path you supply. Read-only, no admin required.                                                                                                                                                                                                                                                              |
| `README.md`                 | This file.                                                                                                                                                                                                                                                                                                                                                                                                                 |

## Usage

Open an **elevated** PowerShell in this directory.

### First install (or full re-run)

```powershell
.\install.ps1
```

### Pin a specific version

```powershell
.\install.ps1 -Version 9.4.1
```

### Re-deploy script + scheduled task without touching winget

```powershell
.\install.ps1 -SkipWinget
```

### Keep old version dirs (skip cleanup)

```powershell
.\install.ps1 -KeepOldVersions
```

By default, after verification passes, the installer removes every
`<ver>` dir under `C:\Program Files\Elastic\Beats\` that isn't the
currently active version. Pass `-KeepOldVersions` to retain them.

The installer is **idempotent** - it's safe to re-run any time.

## What the sample `winlogbeat.yml` collects

The bundled config is a security + reliability baseline tuned for **Windows 11
clients** shipping to **Graylog**. It enables the following event log channels:

| Channel                                                                  | Filter                                      | What it catches                                                                                                                                                                                         |
|--------------------------------------------------------------------------|---------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Security`                                                               | curated event IDs (see below)               | Logon/logoff, account & group changes, AD activity, privilege use, process creation, service install, scheduled tasks, audit policy & log clear, Kerberos, file share access, credential manager, recon |
| `Application`                                                            | `critical, error, warning`                  | .NET runtime crashes, Windows Error Reporting (1000/1001), Application Hang (1002), MSI install failures, app-specific errors                                                                           |
| `System`                                                                 | `critical, error, warning`                  | Service start failures (7000/7001/7011/7034), driver load issues, disk errors (event 7/11/51 — pre-failure signals), time-sync, boot issues                                                             |
| `Microsoft-Windows-PowerShell/Operational`                               | IDs 4103-4106, level `information, warning` | Module logging, script block logging (including Warning-level suspicious-script alerts)                                                                                                                 |
| `Microsoft-Windows-Windows Defender/Operational`                         | all levels                                  | Detections (Warning), engine errors (Error), signature updates                                                                                                                                          |
| `Microsoft-Windows-Sysmon/Operational`                                   | all (requires Sysmon installed)             | Process tree, network connections, file/registry/image-load activity — depends on your Sysmon config                                                                                                    |
| `Microsoft-Windows-TaskScheduler/Operational`                            | all                                         | Task registration / run / completion detail (complements Security 4698)                                                                                                                                 |
| `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`     | all                                         | RDP session lifecycle (IDs 21/22/23/24/25) — who used RDP                                                                                                                                               |
| `Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational` | all                                         | RDP inbound source IP (ID 1149)                                                                                                                                                                         |
| `Microsoft-Windows-WMI-Activity/Operational`                             | all                                         | WMI persistence (T1546.003), lateral movement (T1047)                                                                                                                                                   |
| `Microsoft-Windows-Bits-Client/Operational`                              | all                                         | BITS abuse for download/exfiltration (T1197)                                                                                                                                                            |
| `Microsoft-Windows-CodeIntegrity/Operational`                            | `critical, error, warning`                  | Driver / binary signing failures, WDAC violations                                                                                                                                                       |
| `Microsoft-Windows-PrintService/Operational`                             | all                                         | PrintNightmare-class abuse (driver load)                                                                                                                                                                |
| `Microsoft-Windows-AppLocker/EXE and DLL` + `MSI and Script`             | all                                         | Blocked executions (only emits when AppLocker is configured)                                                                                                                                            |
| `Setup`                                                                  | `critical, error, warning`                  | Servicing / feature install issues                                                                                                                                                                      |

### Security event IDs included

The `Security` channel is **not** set to "everything" - it ships a curated set
that aligns with the NSA "Spotting the Adversary" / Palantir WEF baselines:

- **Logon:** `4624, 4625, 4634, 4647, 4648, 4672, 4778, 4779`
- **Privilege use:** `4673, 4674`
- **Process tracking:** `4688, 4689`
- **Service install:** `4697`
- **Scheduled tasks:** `4698, 4699, 4702`
- **Audit policy / log integrity:** `4719, 4964, 1102`
- **Account management:** `4720, 4722-4726, 4738, 4740, 4767, 4781`
- **Group management:** `4727-4731, 4732-4735, 4737, 4741-4743, 4756-4758`
- **Kerberos:** `4768, 4769, 4771, 4772, 4776`
- **Recon (local group enum):** `4798, 4799`
- **File share access:** `5140, 5145`
- **Object ACL changes:** `4670`
- **Credential Manager:** `5379`

### Sample config knobs you'll commonly want to change

The settings below are the ones that are environment-specific. They're easy to
spot in the file (search by section header):

| Where                                          | Setting                                                     | Default in sample              | When to change                                                                                                             |
|------------------------------------------------|-------------------------------------------------------------|--------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| `output.logstash.hosts`                        | Graylog Beats input host:port                               | `graylog.yourdomain.fqdn:5044` | **Always** - point at your Graylog server. Sample is a placeholder.                                                        |
| `output.logstash`                              | TLS                                                         | off (no `ssl.*` keys)          | If your Graylog Beats input requires TLS, add an `ssl.*` block — see Elastic docs                                          |
| `fields.environment`                           | env tag for routing                                         | `prod`                         | Set to `dev` / `test` / etc. — surfaces as `environment` at the event root                                                 |
| `fields.site`                                  | location tag                                                | `vienna-dc`                    | Set to your site identifier — useful for multi-site dashboards                                                             |
| `processors` (drop_event for 4624/4634)        | drops `LogonType: 3` (network) and `LogonType: 5` (service) | enabled                        | **Remove these blocks on servers / DCs** — network logons are the most interesting events there. They're noise on clients. |
| `winlogbeat.event_logs[Security].event_id`     | curated list                                                | ~55 IDs                        | Add more (e.g. `5136` for AD object changes on DCs) or trim. Don't use `"*"` — drowns Graylog.                             |
| `winlogbeat.event_logs[*].ignore_older`        | starts from N hours ago on first run                        | `24h`                          | Increase if you want to backfill on first start; decrease to ignore old events after a long shipper outage                 |
| `queue.mem`                                    | in-memory event buffer                                      | 4096 events                    | Increase on busy hosts; decrease on memory-constrained boxes                                                               |
| `logging.files.rotateeverybytes`               | local log rotation                                          | 10 MB × 7 files                | Adjust to fit available disk under `C:\Program Files\Elastic\Beats\logs\`                                                  |
| `setup.ilm.enabled` / `setup.template.enabled` | Elasticsearch index management                              | both `false`                   | Leave `false` for Graylog (Graylog manages its own indices). Set `true` only if shipping straight to Elasticsearch.        |

### TLS to Graylog

The sample assumes TLS is **off** on the Graylog Beats input. To enable TLS,
add under `output.logstash`:

```yaml
ssl.enabled: true
ssl.certificate_authorities: ["C:/Program Files/Elastic/Beats/ca.crt"]
ssl.verification_mode: full
```

…and configure the matching cert chain on the Graylog side.

## Config file (`winlogbeat.yml`) behavior

The installer is conservative about your config so that re-runs and
post-upgrade fixes never silently clobber your edits:

| Destination state                                                        | `-ForceConfigOverwrite`? | What happens                                                                                                                               |
|--------------------------------------------------------------------------|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| **No `winlogbeat.yml`** at `C:\Program Files\Elastic\Beats\` (fresh box) | (irrelevant)             | Bundled `winlogbeat.yml` is **copied**, then service is **restarted** to load it                                                           |
| `winlogbeat.yml` already exists                                          | not passed (default)     | **Skipped, existing file kept** -> `[WARN] ... leaving it untouched`. Service is **not restarted** (no change to load).                    |
| `winlogbeat.yml` already exists                                          | passed                   | Existing file backed up to `winlogbeat.yml.bak.<timestamp>`, bundled file is copied, service is **restarted** so the new config is loaded. |

So:

- **Edit the deployed file** (`C:\Program Files\Elastic\Beats\winlogbeat.yml`)
  freely - re-running `install.ps1` will not touch it.
- The **bundled** `winlogbeat.yml` (in this project dir) is the seed only.
  Update it if you want a new fresh-install template; it does not push your
  changes to existing installs.
- The **maintenance script** (`Fix-WinlogbeatService.ps1`), and therefore
  the scheduled task that fires after every MSI upgrade, never touches the
  config either - it only edits the service `binPath`.

To force-replace an existing config with the bundled one:

```powershell
.\install.ps1 -ForceConfigOverwrite
```

## Future upgrades

Once installed, you don't need this installer again to upgrade:

```powershell
winget upgrade --id Elastic.Winlogbeat
```

Within ~30 seconds the scheduled task fires, runs the maintenance script,
and the service is back to using the stable config from the new version dir.
The maintenance script then waits up to 30 s for the service to reach
`Running`, and **only on success** removes the previous versioned install
dirs under `C:\Program Files\Elastic\Beats\`. If the new service fails to
start, the old version dirs are kept for diagnosis / manual rollback.

> **Opt out of automatic cleanup:** the maintenance script also accepts
> `-KeepOldVersions`. Since the scheduled task invokes the script without
> arguments, the way to make the post-upgrade flow keep old dirs is to
> edit the scheduled task's action and append `-KeepOldVersions` to the
> `-File` argument (or replace the deployed script with a wrapper).

## What gets created on the system

| Path                                                       | Contents                                        |
|------------------------------------------------------------|-------------------------------------------------|
| `C:\Program Files\Elastic\Beats\winlogbeat.yml`            | Stable config                                   |
| `C:\Program Files\Elastic\Beats\Fix-WinlogbeatService.ps1` | Maintenance script                              |
| `C:\Program Files\Elastic\Beats\data\`                     | Stable shipper state (event registry, lockfile) |
| `C:\Program Files\Elastic\Beats\logs\`                     | Stable beat logs                                |
| `C:\Program Files\Elastic\Beats\<ver>\winlogbeat\`         | Versioned install dir (managed by winget/MSI)   |
| Scheduled task `Fix-WinlogbeatService-OnMsiInstall`        | Auto-reconfig trigger                           |
| Service `winlogbeat` (binPath rewritten)                   | Reads stable config                             |

## Verification

The installer runs a verification pass at the end. To re-check at any time:

```powershell
# Service status
Get-Service winlogbeat

# Service binPath
sc.exe qc winlogbeat | Select-String BINARY_PATH_NAME

# Scheduled task health
Get-ScheduledTaskInfo -TaskName Fix-WinlogbeatService-OnMsiInstall

# Run the maintenance script manually (idempotent)
& "C:\Program Files\Elastic\Beats\Fix-WinlogbeatService.ps1"
```

### Validating the config (`check_config.ps1`)

`check_config.ps1` runs `winlogbeat.exe test config` and `test output`
against a config file using the newest installed `winlogbeat.exe`. It uses
a private temp `--path.data` so it never disturbs the running service's
registry / lockfile, and it does **not** require admin rights.

```powershell
# Check the deployed stable config (default)
.\check_config.ps1

# Check the bundled config in this directory before deploying
.\check_config.ps1 -Bundled

# Check an arbitrary file
.\check_config.ps1 -ConfigPath C:\tmp\test.yml

# Skip the output reachability test (doesn't try to talk to Graylog)
.\check_config.ps1 -SkipOutputTest
```

Exit code `0` = all checks passed, `1` = one or more failed.

## Uninstall

```powershell
# Stop and remove the service via winget
winget uninstall --id Elastic.Winlogbeat

# Remove the scheduled task
Unregister-ScheduledTask -TaskName Fix-WinlogbeatService-OnMsiInstall -Confirm:$false

# Optional: remove stable config and state
Remove-Item -Recurse -Force "C:\Program Files\Elastic\Beats\winlogbeat.yml",
                            "C:\Program Files\Elastic\Beats\Fix-WinlogbeatService.ps1",
                            "C:\Program Files\Elastic\Beats\data",
                            "C:\Program Files\Elastic\Beats\logs"
```

## Notes / caveats

- **Run elevated.** All write operations target `C:\Program Files\` and modify
  service configuration; the installer enforces this with `#Requires -RunAsAdministrator`.
- **PowerShell 5.1 compatibility.** The maintenance script is loaded via
  `powershell.exe -File`, which uses Windows PowerShell 5.1. Keep it ASCII-only
  - non-ASCII characters in a UTF-8-without-BOM file will trigger a parser
  error.
- **Stale version dirs.** `winget`/MSI does not remove old versioned install
  dirs under `C:\Program Files\Elastic\Beats\`. The installer cleans them up
  automatically after a successful verification (pass `-KeepOldVersions` to
  opt out). The maintenance script always picks the highest version that
  matches `^\d+\.\d+\.\d+$`, so cleanup never affects what the service runs.
- **Scheduled task trigger** fires on **any** MSI install on the system, not
  just Winlogbeat upgrades. The maintenance script is idempotent: if nothing
  changed, it's a fast no-op.
