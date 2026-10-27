#Requires -Version 5.1
<#
.SYNOPSIS
    Background watcher: runs the primary sopalin backup at logon and triggers
    backup.ps1 again whenever external drive I: is connected.

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

Write-WatcherLog "===== Watcher started; primary destination is sopalin ====="

try {
    $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"
    Register-CimIndicationEvent -Query $query -SourceIdentifier $SourceId | Out-Null

    Write-WatcherLog "Running startup backup (sopalin; I: is included if mounted)."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BackupScript
    Write-WatcherLog "Startup backup invocation finished (exit code $LASTEXITCODE)."

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
