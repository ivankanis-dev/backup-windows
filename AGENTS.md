# Copilot instructions

This repository contains PowerShell scripts backing up `C:\` and `D:\` with
restic to `rclone:sopalin:restic-backup/<hostname>` and, when mounted, to
`I:\restic-backup\<hostname>`. No test suite or linter is configured.

## Architecture and conventions

- `Watch-DriveConnect.ps1` runs the remote backup at logon and invokes
  `backup.ps1` when I: connects.
- `backup.ps1` handles `sopalin` first, then I: if available. Each repository
  has independent daily/prune markers. It initializes repositories as needed,
  backs up with VSS and `restic-excludes.txt`, and reports failures after
  attempting each destination.
- `Setup-ResticBackupTask.ps1` checks restic, rclone, and the account's
  `sopalin` remote, creates the password file if absent, and registers the
  logon task.
- Keep the rclone configuration and `restic-password.txt` out of source
  control. Keep generated markers and `restic-cache\` ignored.
- Use `$PSScriptRoot` for local paths. Keep the I: drive letter consistent in
  `backup.ps1` and `Watch-DriveConnect.ps1`.
- Add excludes to `restic-excludes.txt`, not inline flags.
- Preserve timestamped logging to `logs\` and repeated-run safety. The
  single-instance guard is the named mutex `Global\ResticBackupCD` in
  `backup.ps1`.
- Target Windows PowerShell 5.1 (`#Requires -Version 5.1`). Avoid PowerShell 7
  only syntax such as `?:`, `??`, and `&&`/`||` pipeline chains.
- Native `restic`/`rclone` calls run with `$ErrorActionPreference` temporarily
  set to `Continue` and are checked through `$LASTEXITCODE`. Follow this
  pattern. `restic` exit code 3 (partial read) counts as success with warnings.

## Validation

After editing a `.ps1`, parse-check it:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    ".\<script>.ps1", [ref]$null, [ref]$errors)
$errors.Count
```

There are no automated tests, linter, or build step, so there is no single-test
command. Do not assume live access to rclone or the configured remote.

Running `.\backup.ps1` performs real backups and prune operations against
`sopalin` and I:. Do not run it to verify edits unless the user asks.
`Setup-ResticBackupTask.ps1` must run elevated and changes the scheduled task.
Do not run it either.
