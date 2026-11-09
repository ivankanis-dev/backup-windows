#Requires -Version 5.1
<#
.SYNOPSIS
    Restic backup of C:\ and D:\ to the sopalin rclone remote and, when
    available, an external hard drive (I:), using restic's native VSS support.
    Triggered automatically at logon and whenever drive I: is plugged in.

.NOTES
    - Requires restic on PATH.
    - Requires the rclone remote named 'sopalin' to be configured.
    - Drive I: is optional and receives its own repository when connected.
    - Requires restic-password.txt to exist next to this script (created by
      Setup-ResticBackupTask.ps1).
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$BackupRoot    = $PSScriptRoot
$DriveLetter   = 'I:'
# $RemoteRepoPath = "rclone:sopalin:restic-backup/$env:COMPUTERNAME"
$RemoteRepoPath = ""
$LocalRepoPath = '{0}\restic-backup\{1}' -f $DriveLetter, $env:COMPUTERNAME
$ExcludeFile   = Join-Path $BackupRoot 'restic-excludes.txt'
$PasswordFile  = Join-Path $BackupRoot 'restic-password.txt'
$CacheDir      = Join-Path $BackupRoot 'restic-cache'
$LogDir        = Join-Path $BackupRoot 'logs'
$LockFile      = Join-Path $BackupRoot 'backup.lock'
$LocalPruneMarker = Join-Path $BackupRoot 'last-prune.txt'
$RemotePruneMarker = Join-Path $BackupRoot 'last-prune-sopalin.txt'
$LocalBackupMarker = Join-Path $BackupRoot 'last-backup.txt'
$RemoteBackupMarker = Join-Path $BackupRoot 'last-backup-sopalin.txt'
$PruneEveryDays = 7
$KeepDaily     = 21
$KeepWeekly    = 4
$KeepMonthly   = 6
$BackupPaths   = @('C:\', 'D:\')

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

function Show-Toast {
    param(
        [string]$Title,
        [string]$Text,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Severity = 'Info'
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = switch ($Severity) {
            'Error'   { [System.Drawing.SystemIcons]::Warning }
            'Warning' { [System.Drawing.SystemIcons]::Warning }
            default   { [System.Drawing.SystemIcons]::Information }
        }
        $notify.Visible = $true
        $notify.BalloonTipIcon = switch ($Severity) {
            'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
            'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
            default   { [System.Windows.Forms.ToolTipIcon]::Info }
        }
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

function Invoke-RepositoryBackup {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$BackupMarker,
        [Parameter(Mandatory)][string]$PruneMarker,
        [Parameter(Mandatory)][string]$Today
    )

    $env:RESTIC_REPOSITORY = $Repository
    Write-Log "[$Destination] Repository: $Repository"

    if (Test-Path $BackupMarker) {
        $lastBackupDate = (Get-Content $BackupMarker -Raw).Trim()
        if ($lastBackupDate -eq $Today) {
            Write-Log "[$Destination] Already backed up today ($Today). Skipping."
            return
        }
    }

    Write-Log "[$Destination] Checking repository status..."
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & restic cat config *> $null
        $repoCheckExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    if ($repoCheckExit -ne 0) {
        Write-Log "[$Destination] Repository not initialized yet. Running 'restic init'..."
        $initOutput = & restic init 2>&1
        $initExit = $LASTEXITCODE
        $initOutput | ForEach-Object { Write-Log "[$Destination]   $_" }
        if ($initExit -ne 0) {
            throw "[$Destination] restic init failed with exit code $initExit"
        }
        Write-Log "[$Destination] Repository initialized."
    } else {
        Write-Log "[$Destination] Repository already initialized."
    }

    Write-Log "[$Destination] Starting restic backup of: $($BackupPaths -join ', ')"
    $backupArgs = @(
        'backup'
    ) + $BackupPaths + @(
        '--use-fs-snapshot',
        '--exclude-file', $ExcludeFile,
        '--tag', 'daily'
    )

    $backupOutput = & restic @backupArgs 2>&1
    $backupExit = $LASTEXITCODE
    $backupOutput | ForEach-Object { Write-Log "[$Destination]   $_" }

    if ($backupExit -eq 0) {
        Write-Log "[$Destination] Backup completed successfully."
        Set-Content -Path $BackupMarker -Value $Today -NoNewline
    } elseif ($backupExit -eq 3) {
        Write-Log "[$Destination] Backup completed with warnings (some files could not be read). Exit code 3."
        Set-Content -Path $BackupMarker -Value $Today -NoNewline
    } else {
        throw "[$Destination] restic backup failed with exit code $backupExit"
    }

    $shouldPrune = $true
    if (Test-Path $PruneMarker) {
        $lastPrune = Get-Content $PruneMarker -Raw | ForEach-Object { [datetime]::Parse($_.Trim()) }
        if (((Get-Date) - $lastPrune).TotalDays -lt $PruneEveryDays) {
            $shouldPrune = $false
            Write-Log "[$Destination] Skipping prune (last prune was $([math]::Round(((Get-Date) - $lastPrune).TotalDays,1)) days ago, threshold is $PruneEveryDays days)."
        }
    }

    if ($shouldPrune) {
        Write-Log "[$Destination] Running forget/prune (keep-daily=$KeepDaily keep-weekly=$KeepWeekly keep-monthly=$KeepMonthly)..."
        $forgetOutput = & restic forget --keep-daily $KeepDaily --keep-weekly $KeepWeekly --keep-monthly $KeepMonthly --prune 2>&1
        $forgetExit = $LASTEXITCODE
        $forgetOutput | ForEach-Object { Write-Log "[$Destination]   $_" }
        if ($forgetExit -ne 0) {
            throw "[$Destination] restic forget/prune failed with exit code $forgetExit"
        }
        Get-Date -Format 'o' | Set-Content -Path $PruneMarker
        Write-Log "[$Destination] Prune completed."
    }
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
    $today = Get-Date -Format 'yyyy-MM-dd'

    if (-not (Test-Path $PasswordFile)) {
        throw "Password file not found at $PasswordFile. Run Setup-ResticBackupTask.ps1 first."
    }

    $failures = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($RemoteRepoPath)) {
        Write-Log "RemoteRepoPath is empty. Skipping sopalin (cloud) backup."
    } else {
        try {
            Invoke-RepositoryBackup -Destination 'sopalin' -Repository $RemoteRepoPath `
                -BackupMarker $RemoteBackupMarker -PruneMarker $RemotePruneMarker -Today $today
        } catch {
            $failures.Add($_.Exception.Message)
            Write-Log "ERROR: $($_.Exception.Message)"
        }
    }

    if (Test-Path "$DriveLetter\") {
        try {
            Invoke-RepositoryBackup -Destination $DriveLetter -Repository $LocalRepoPath `
                -BackupMarker $LocalBackupMarker -PruneMarker $LocalPruneMarker -Today $today
        } catch {
            $failures.Add($_.Exception.Message)
            Write-Log "ERROR: $($_.Exception.Message)"
        }
    } else {
        Write-Log "Drive $DriveLetter not found. Skipping local backup."
    }

    if ($failures.Count -gt 0) {
        throw "One or more backup destinations failed: $($failures -join '; ')"
    }

    Write-Log "===== Backup run finished successfully ====="
    Show-Toast -Title 'Restic backup finished' -Text "Backup of $($BackupPaths -join ', ') completed." -Severity Info
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "ERROR: $errMsg"
    Write-Log "===== Backup run FAILED ====="
    Show-Toast -Title 'Restic backup failed' -Text "$errMsg`nSee log: $LogFile" -Severity Error
    exit 1
}
finally {
    Remove-OldLogs
    if ($acquired) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
