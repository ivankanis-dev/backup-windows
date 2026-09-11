# Copilot instructions for this repository

This repo is a small set of PowerShell scripts (not an application codebase)
that implement a restic-based backup of `C:\` and `D:\` to an external hard
drive mounted as `I:`. There is no build system, package manifest, test
suite, or linter — validate changes by parsing/running the scripts directly.

## Validating changes

There are no automated tests. After editing any `.ps1` file, at minimum
parse-check it for syntax errors:

```powershell
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "C:\Users\ikanis\backup\<file>.ps1", [ref]$null, [ref]$errs)
$errs.Count   # should be 0
```

For behavioral changes to `backup.ps1`, do a manual dry run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
```

and check `logs\backup-<yyyyMMdd>.log`. `backup.ps1` is safe to run
repeatedly/manually — it no-ops (exit 0) if drive `I:` isn't present, and a
`Global\ResticBackupCD` named mutex prevents overlapping runs. It also
skips (exit 0) if `last-backup.txt` already records today's date, so
delete that file first if you need to force a second backup on the same
day while testing.

## Architecture

Three scripts cooperate around one restic repository stored on the external
drive at `I:\restic-backup\<hostname>`:

- **`Watch-DriveConnect.ps1`** — long-running background watcher, started
  hidden at user logon by the scheduled task. Subscribes to a
  `Win32_VolumeChangeEvent` (EventType 2 = device arrival) via
  `Register-CimIndicationEvent` and invokes `backup.ps1` whenever the new
  volume is drive `I:` (also fires once immediately if `I:` is already
  connected at watcher startup). Logs to `logs\watcher.log`.
- **`backup.ps1`** — the actual worker: checks `I:` is present, skips if
  `last-backup.txt` already shows today's date (once-per-day guard — the
  watcher/manual runs can fire multiple times a day), sets restic env vars
  (`RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, `RESTIC_CACHE_DIR`), lazily
  runs `restic init` on first use, backs up `C:\` and `D:\` with
  `--use-fs-snapshot` (native VSS) and `restic-excludes.txt`, records
  today's date to `last-backup.txt` on success/warnings-only, then
  throttles `restic forget --prune` to at most once every 7 days (tracked
  via `last-prune.txt`). Retention: 21 daily / 4 weekly / 6 monthly
  snapshots. Logs to `logs\backup-<yyyyMMdd>.log` (last 30 kept); shows a
  Windows balloon/toast notification only on failure.
- **`Setup-ResticBackupTask.ps1`** — one-time, run elevated manually. Generates
  `restic-password.txt` (random passphrase, ACL locked to current user +
  SYSTEM + Administrators) if it doesn't already exist, then registers the
  `ResticBackupWatcher-I` Scheduled Task (`-AtLogOn` trigger, runs
  `Watch-DriveConnect.ps1` hidden, auto-restarts on failure). Safe to re-run.

Key invariant: there is no fixed daily schedule — everything is driven off
drive-connect events, so `backup.ps1` must remain safe to invoke repeatedly
and idempotent about repo initialization.

## Conventions

- All three scripts derive paths from `$PSScriptRoot`/`$BackupRoot` — never
  hardcode paths outside this folder except the `I:` drive letter and
  `restic-password.txt`'s ACL identities.
- Logging pattern used everywhere: a local `Write-*Log` function that
  timestamps (`yyyy-MM-dd HH:mm:ss`) and appends to a log file under
  `logs\`, mirrored to stdout via `Write-Output`.
- `restic-password.txt` and `restic-cache\` must never be committed/synced
  elsewhere; they're excluded from source control expectations by design
  (see README security note).
- `restic-excludes.txt` is the single source of truth for exclude patterns
  (pagefile/hiberfil, `$Recycle.Bin`, `System Volume Information`, temp
  dirs, restic's own cache) — add new excludes there, not as inline
  `--exclude` flags in `backup.ps1`.
- Drive letter `I:` is currently hardcoded in both `backup.ps1`
  (`$DriveLetter`) and `Watch-DriveConnect.ps1` (`$DriveLetter`); keep them
  in sync if it ever changes.
