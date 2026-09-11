#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time setup for the restic backup of C:\ and D:\ to external hard
    drive I:.

    Run this ONCE, from an elevated PowerShell prompt, as the user account
    that will run backups. It will:
      1. Generate restic-password.txt (random passphrase). The drive is
         BitLocker-encrypted, so no additional NTFS ACL lockdown is applied.
      2. Register a Scheduled Task that starts Watch-DriveConnect.ps1 at
         logon; it runs hidden in the background and triggers backup.ps1
         automatically whenever drive I: is connected.

    Prerequisites (do this BEFORE running this script):
      - Install restic:      winget install restic.restic
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'ResticBackupWatcher-I'
)

$ErrorActionPreference = 'Stop'
$BackupRoot    = $PSScriptRoot
$PasswordFile  = Join-Path $BackupRoot 'restic-password.txt'
$ScriptPath    = Join-Path $BackupRoot 'backup.ps1'
$WatcherPath   = Join-Path $BackupRoot 'Watch-DriveConnect.ps1'

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if (-not (Get-Command restic -ErrorAction SilentlyContinue)) {
    throw "restic was not found on PATH. Install it first: winget install restic.restic"
}

# ---------------------------------------------------------------------------
# 1. Generate the restic repository password file
# ---------------------------------------------------------------------------
if (Test-Path $PasswordFile) {
    Write-Host "Password file already exists at $PasswordFile - leaving it untouched."
} else {
    Write-Host "Generating a new restic repository password..."
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes)
    Set-Content -Path $PasswordFile -Value $password -NoNewline
    Write-Host "Password file created at $PasswordFile"
    Write-Warning "IMPORTANT: back this password up somewhere safe (e.g. a password manager). Without it the backups CANNOT be restored."
}

# ---------------------------------------------------------------------------
# 2. Register the Scheduled Task: starts the watcher at logon, which runs
#    hidden in the background and triggers backup.ps1 whenever drive I: is
#    connected (no fixed daily schedule needed).
# ---------------------------------------------------------------------------
Write-Host "Registering scheduled task '$TaskName'..."

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatcherPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Watches for external drive I: and runs a restic backup of C: and D: to it (VSS snapshot) whenever it is connected.' `
    -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered: starts the watcher at logon; it runs continuously and triggers a backup each time drive I: is plugged in."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Log off/on once (or start the task now: Start-ScheduledTask -TaskName '$TaskName')."
Write-Host "  2. Test manually now:   powershell -File `"$ScriptPath`""
Write-Host "  3. Check the logs in:   $BackupRoot\logs\ (backup-*.log and watcher.log)"
