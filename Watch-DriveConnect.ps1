#Requires -Version 5.1
<#
.SYNOPSIS
    Background watcher: waits for external drive I: to be connected, then
    triggers backup.ps1. Runs indefinitely; intended to be started hidden
    at user logon by the ResticBackupWatcher-I scheduled task.

.NOTES
    Uses a WMI Win32_VolumeChangeEvent subscription (EventType 2 = device
    arrival) rather than parsing Event Viewer logs, since drive-letter
    assignment events aren't reliably logged there.
#>

$ErrorActionPreference = 'Stop'
$BackupRoot   = $PSScriptRoot
$DriveLetter  = 'I:'
$BackupScript = Join-Path $BackupRoot 'backup.ps1'
$LogDir       = Join-Path $BackupRoot 'logs'
$LogFile      = Join-Path $LogDir 'watcher.log'
$SourceId     = 'ResticDriveIArrival'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-WatcherLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
}

Write-WatcherLog "===== Watcher started, waiting for drive $DriveLetter ====="

# If the drive is already connected at logon, kick off a backup immediately.
if (Test-Path "$DriveLetter\") {
    Write-WatcherLog "Drive $DriveLetter already connected at startup. Running backup."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BackupScript
}

try {
    $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"
    Register-CimIndicationEvent -Query $query -SourceIdentifier $SourceId | Out-Null

    while ($true) {
        $event = Wait-Event -SourceIdentifier $SourceId
        try {
            $driveName = $event.SourceEventArgs.NewEvent.DriveName
            if ($driveName -eq $DriveLetter) {
                Write-WatcherLog "Drive $DriveLetter connected. Starting backup."
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BackupScript
                Write-WatcherLog "Backup invocation finished (exit code $LASTEXITCODE)."
            }
        } catch {
            Write-WatcherLog "ERROR handling volume arrival event: $_"
        } finally {
            Remove-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Unregister-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
    Write-WatcherLog "===== Watcher stopped ====="
}
