#Requires -Version 5.1
<#
.SYNOPSIS
    Restic backup of C:\ and D:\ to an external hard drive (I:), using
    restic's native VSS support. Triggered automatically (via a background
    watcher, see Watch-DriveConnect.ps1) whenever drive I: is plugged in;
    can also be run manually at any time.

.NOTES
    - Requires restic on PATH.
    - Requires the external drive to be connected and assigned letter I:.
    - Requires restic-password.txt to exist next to this script (created by
      Setup-ResticBackupTask.ps1).
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$BackupRoot    = $PSScriptRoot
$DriveLetter   = 'I:'
$RepoPath      = Join-Path "$DriveLetter\" "restic-backup\$env:COMPUTERNAME"
$ExcludeFile   = Join-Path $BackupRoot 'restic-excludes.txt'
$PasswordFile  = Join-Path $BackupRoot 'restic-password.txt'
$CacheDir      = Join-Path $BackupRoot 'restic-cache'
$LogDir        = Join-Path $BackupRoot 'logs'
$LockFile      = Join-Path $BackupRoot 'backup.lock'
$PruneMarker   = Join-Path $BackupRoot 'last-prune.txt'
$LastBackupMarker = Join-Path $BackupRoot 'last-backup.txt'
$PruneEveryDays = 7
$KeepDaily     = 21
$KeepWeekly    = 4
$KeepMonthly   = 6
$BackupPaths   = @('C:\', 'D:\')

# ---------------------------------------------------------------------------
# Bail out early (quietly) if the external drive isn't connected. This lets
# the watcher/manual invocation call this script freely without spurious
# failure toasts when I: isn't plugged in.
# ---------------------------------------------------------------------------
if (-not (Test-Path "$DriveLetter\")) {
    Write-Output "Drive $DriveLetter not found. Skipping backup."
    exit 0
}

$env:RESTIC_REPOSITORY   = $RepoPath
$env:RESTIC_PASSWORD_FILE = $PasswordFile
$env:RESTIC_CACHE_DIR    = $CacheDir

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile   = Join-Path $LogDir "backup-$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

function Show-FailureToast {
    param([string]$Title, [string]$Text)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Warning
        $notify.Visible = $true
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Text
        $notify.ShowBalloonTip(15000)
        Start-Sleep -Seconds 1
        # Keep the icon alive long enough for the balloon to render, then dispose.
        Start-Sleep -Seconds 5
        $notify.Dispose()
    } catch {
        Write-Log "Could not show toast notification: $_"
    }
}

function Remove-OldLogs {
    Get-ChildItem -Path $LogDir -Filter 'backup-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Single-instance guard (avoid overlapping runs, e.g. catch-up + scheduled)
# ---------------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\ResticBackupCD')
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}

if (-not $acquired) {
    Write-Log "Another backup run is already in progress. Exiting."
    exit 0
}

try {
    Write-Log "===== Backup run started ====="
    Write-Log "Repository: $env:RESTIC_REPOSITORY"

    # -----------------------------------------------------------------
    # Only back up once per calendar day, even if the drive is connected/
    # the watcher fires multiple times (or the script is run manually
    # again) on the same day.
    # -----------------------------------------------------------------
    $today = Get-Date -Format 'yyyy-MM-dd'
    if (Test-Path $LastBackupMarker) {
        $lastBackupDate = (Get-Content $LastBackupMarker -Raw).Trim()
        if ($lastBackupDate -eq $today) {
            Write-Log "Already backed up today ($today). Skipping."
            Write-Log "===== Backup run skipped (already done today) ====="
            exit 0
        }
    }

    if (-not (Test-Path $PasswordFile)) {
        throw "Password file not found at $PasswordFile. Run Setup-ResticBackupTask.ps1 first."
    }

    # -----------------------------------------------------------------
    # Ensure the repository is initialized (first run only)
    # -----------------------------------------------------------------
    Write-Log "Checking repository status..."
    # Temporarily relax ErrorActionPreference: with it set to 'Stop', restic's
    # stderr output (e.g. "repository does not exist") is converted to a
    # terminating error the moment it's written, even though it's redirected
    # to $null below, causing this check to throw instead of falling through
    # to the 'restic init' branch.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & restic cat config *> $null
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Repository not initialized yet. Running 'restic init'..."
        $initOutput = & restic init 2>&1
        $initOutput | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "restic init failed with exit code $LASTEXITCODE"
        }
        Write-Log "Repository initialized."
    } else {
        Write-Log "Repository already initialized."
    }

    # -----------------------------------------------------------------
    # Run the backup (VSS snapshot handled natively by restic on Windows)
    # -----------------------------------------------------------------
    Write-Log "Starting restic backup of: $($BackupPaths -join ', ')"
    $backupArgs = @(
        'backup'
    ) + $BackupPaths + @(
        '--use-fs-snapshot',
        '--exclude-file', $ExcludeFile,
        '--tag', 'daily'
    )

    $backupOutput = & restic @backupArgs 2>&1
    $backupExit = $LASTEXITCODE
    $backupOutput | ForEach-Object { Write-Log "  $_" }

    if ($backupExit -eq 0) {
        Write-Log "Backup completed successfully."
        Set-Content -Path $LastBackupMarker -Value $today -NoNewline
    } elseif ($backupExit -eq 3) {
        Write-Log "Backup completed with warnings (some files could not be read). Exit code 3."
        Set-Content -Path $LastBackupMarker -Value $today -NoNewline
    } else {
        throw "restic backup failed with exit code $backupExit"
    }

    # -----------------------------------------------------------------
    # Retention: forget + prune, throttled to once every N days since
    # the laptop won't run every single day anyway.
    # -----------------------------------------------------------------
    $shouldPrune = $true
    if (Test-Path $PruneMarker) {
        $lastPrune = Get-Content $PruneMarker -Raw | ForEach-Object { [datetime]::Parse($_.Trim()) }
        if (((Get-Date) - $lastPrune).TotalDays -lt $PruneEveryDays) {
            $shouldPrune = $false
            Write-Log "Skipping prune (last prune was $([math]::Round(((Get-Date) - $lastPrune).TotalDays,1)) days ago, threshold is $PruneEveryDays days)."
        }
    }

    if ($shouldPrune) {
        Write-Log "Running forget/prune (keep-daily=$KeepDaily keep-weekly=$KeepWeekly keep-monthly=$KeepMonthly)..."
        $forgetOutput = & restic forget --keep-daily $KeepDaily --keep-weekly $KeepWeekly --keep-monthly $KeepMonthly --prune 2>&1
        $forgetExit = $LASTEXITCODE
        $forgetOutput | ForEach-Object { Write-Log "  $_" }
        if ($forgetExit -ne 0) {
            throw "restic forget/prune failed with exit code $forgetExit"
        }
        Get-Date -Format 'o' | Set-Content -Path $PruneMarker
        Write-Log "Prune completed."
    }

    Write-Log "===== Backup run finished successfully ====="
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "ERROR: $errMsg"
    Write-Log "===== Backup run FAILED ====="
    Show-FailureToast -Title 'Restic backup failed' -Text "$errMsg`nSee log: $LogFile"
    exit 1
}
finally {
    Remove-OldLogs
    if ($acquired) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
