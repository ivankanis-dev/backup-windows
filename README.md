# Restic Backup

Backs up `C:\` and `D:\` with native VSS snapshots to the rclone remote
`sopalin:restic-backup/<hostname>`. When I: is mounted, it also writes a
separate repository to `I:\restic-backup\<hostname>`.

## Setup

1. Install `restic` and `rclone`; configure `sopalin` for the account that
   will run the scheduled task. Keep that account's rclone credentials private.
2. From an elevated PowerShell session running as that account, run:
   ```powershell
   .\Setup-ResticBackupTask.ps1
   ```
   The script checks for `restic`, `rclone`, and the `sopalin` remote, creates
   `restic-password.txt` if needed, and registers the logon watcher. Store the
   password safely; without it, repositories cannot be restored.
3. Run `.\backup.ps1` manually or let the watcher start at logon. It backs up
   to `sopalin` first, then to I: if mounted. Each destination is attempted
   independently and backed up at most once per day.

## Operation

The watcher runs the remote backup at logon and invokes it again when I:
connects. Daily and prune markers are independent: `last-backup-sopalin.txt`
and `last-prune-sopalin.txt` track the remote; `last-backup.txt` and
`last-prune.txt` track I:. Pruning runs at most once every seven days per
repository, retaining 21 daily, 4 weekly, and 6 monthly snapshots.

Logs are in `logs\backup-<yyyyMMdd>.log` and `logs\watcher.log`. Backup or
prune failures show a Windows notification. Repositories use the same
`restic-password.txt`; never commit or share it.

## Snapshots and restore

Set the repository and password file to inspect snapshots or restore:

```powershell
$env:RESTIC_REPOSITORY = "rclone:sopalin:restic-backup/$env:COMPUTERNAME"
$env:RESTIC_PASSWORD_FILE = "$PSScriptRoot\restic-password.txt"
restic snapshots
restic restore latest --target C:\restore-test
```

For the I: repository, set `RESTIC_REPOSITORY` to
`I:\restic-backup\$env:COMPUTERNAME`. Restore to a separate folder to avoid
overwriting files.

Remove the scheduled task with
`Unregister-ScheduledTask -TaskName ResticBackupWatcher-I -Confirm:$false`.
This leaves both repositories and local files untouched.
