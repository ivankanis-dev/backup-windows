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
- Preserve timestamped logging to `logs\` and repeated-run safety.

## Validation

After editing a `.ps1`, parse-check it:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    ".\<script>.ps1", [ref]$null, [ref]$errors)
$errors.Count
```

There are no automated tests. Do not assume live access to rclone or the
configured remote.
