<#
Deploy + schedule winget update script with one-time agreement accepting.
 - OVERWRITES: C:\Intune\Winget\winget-update-any-apps-v2.8.ps1
 - Removes any scheduled tasks whose names contain "Winget upgrade" or "Winget update" (excluding the current task name)
 - Registers task: Winget Update Any Apps v2.8 (Compatibility Win8 -> shows as Windows 10)
 - Daily at 11:00 local time under SYSTEM (highest privileges)
 - Immediate run after creation (toggle $ImmediateRun)
 - Detection file: winget_update_any_apps_v2.8.log
 - Debug log file: winget_update_any_apps_v2.8_debug.log
#>

$ScriptPath    = 'C:\Intune\Winget\winget-update-any-apps-v2.8.ps1'
$TaskName      = 'Winget Update Any Apps v2.8'
$RunTime       = '11:00'      # HH:MM 24h
$ImmediateRun  = $true
$RemoveLegacy  = $true

function Remove-WingetUpgradeOrUpdateTasks {
    param(
        [string]$CurrentTaskName = '',
        [switch]$VerboseOutput
    )
    # Remove any scheduled task with name containing "Winget upgrade" OR "Winget update"
    # Excludes the current task name if it already exists.
    Write-Host "Scanning for tasks containing 'Winget upgrade' or 'Winget update'..." -ForegroundColor Cyan
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    if (-not $allTasks) {
        Write-Host "No tasks retrieved (insufficient rights or none exist)." -ForegroundColor Yellow
        return
    }

    $toRemove = $allTasks | Where-Object {
        (($_.TaskName -match '(?i)Winget\s+upgrade') -or ($_.TaskName -match '(?i)Winget\s+update')) -and
        ($CurrentTaskName -eq '' -or $_.TaskName -ne $CurrentTaskName)
    }

    if (-not $toRemove -or $toRemove.Count -eq 0) {
        Write-Host "No matching 'Winget upgrade/update' tasks found." -ForegroundColor Green
        return
    }

    foreach ($task in $toRemove) {
        $tName  = $task.TaskName
        $tPath  = $task.TaskPath
        if ($VerboseOutput) {
            Write-Host "Removing task: Path='$tPath' Name='$tName'" -ForegroundColor Magenta
        } else {
            Write-Host "Removing task: $tName" -ForegroundColor Magenta
        }
        try {
            Unregister-ScheduledTask -TaskName $tName -TaskPath $tPath -Confirm:$false -ErrorAction Stop
            Write-Host "Removed: $tName" -ForegroundColor Green
        } catch {
            Write-Host "FAILED to remove '$tName': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Ensure directory
$scriptDir = Split-Path $ScriptPath -Parent
if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
}

# Embedded update script content (ALWAYS overwritten)
$upgradeScriptContent = @'
<#
Winget bulk update script (v2.8):
 - File name: winget-update-any-apps-v2.8.ps1
 - BaseDir: C:\Intune\Winget
 - Detection file: winget_update_any_apps_v2.8.log
 - Debug log file: winget_update_any_apps_v2.8_debug.log
 - Event Log source: Winget Apps Update Any
 - One-time accepting of winget agreements at start (non-interactive)
 - Single attempt per app
 - Skips Microsoft.AppInstaller
 - Essential logging only
#>
# EXCLUSION LIST (placed near the top for visibility)
$ExcludedIds = @(
    "Microsoft.CompanyPortal",
    "Microsoft.Edge",
    "Microsoft.LAPS",
    "Microsoft.Office",
    "Microsoft.OneDrive",
    "Microsoft.PowerBI",
    "Microsoft.Teams"
)

$logSource  = 'Winget Apps Update Any'
$baseDir    = 'C:\Intune\Winget'
if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force | Out-Null }
$logFile    = Join-Path $baseDir 'winget_update_any_apps_v2.8_debug.log'
$detectFile = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\winget_update_any_apps_v2.8.log'

# Resolve winget (fallback to PATH)
$wingetExe = $null
try {
    $wingetFolders = Get-ChildItem -Path 'C:\Program Files\WindowsApps\' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' } |
        Sort-Object Name -Descending
    if ($wingetFolders.Count -gt 0) {
        $candidate = Join-Path $wingetFolders[0].FullName 'winget.exe'
        if (Test-Path $candidate) { $wingetExe = $candidate }
    }
} catch {}
if (-not $wingetExe) { $wingetExe = 'winget' }

function Log-Event {
    param([string]$Message,[string]$Type='Information',[int]$EventId=1000)
    $stamp = (Get-Date -Format s)
    $line  = "[$Type][$EventId][$stamp] $Message"
    try { Add-Content -Path $logFile -Value $line } catch {}
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($logSource)) {
            New-EventLog -LogName Application -Source $logSource
        }
        Write-EventLog -LogName Application -Source $logSource -EntryType $Type -EventId $EventId -Message $Message
    } catch {}
}

Log-Event "Winget update script starting." 'Information' 1000

# Log resolved winget.exe path
Log-Event ("Resolved winget path: {0}" -f $wingetExe) 'Information' 1002

# One-time accepting of winget source/package agreements under SYSTEM
try {
    Log-Event "Accepting winget agreements (non-interactive)..." 'Information' 1008
    $null = & $wingetExe source list --accept-source-agreements --disable-interactivity 2>&1
    $null = & $wingetExe upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    Log-Event "Accepting agreements completed." 'Information' 1009
} catch {
    Log-Event ("Accepting agreements failed (continuing): {0}" -f $_.Exception.Message) 'Warning' 1200
}

# Discovery (same logic as your working version)
$raw = & $wingetExe upgrade 2>&1

function Test-IsVersionToken { param([string]$Token) return ($Token -match '^\d+(\.\d+)+$') }

$appIds = @()
$headerFound = $false
foreach ($line in $raw) {
    if ($line -match '^\s*Name\s+Id\s+Version\s+Available\s+Source') { $headerFound = $true; continue }
    if ($headerFound) {
        if ($line -match '^-{5,}') { continue }
        if ($line.Trim() -eq "" -or $line -like "*upgrade*available*") { break }
        $tokens = $line -split '\s+'
        $chosenId = $null
        foreach ($token in $tokens) {
            $tk = $token.Trim()
            if ($tk -match '\.' -and $tk -notmatch '\s') {
                if (Test-IsVersionToken $tk) { continue }
                if ($tk -eq 'winget') { continue }
                $chosenId = $tk; break
            }
        }
        if ($chosenId -and -not $appIds.Contains($chosenId)) {
            $appIds += $chosenId
            Log-Event "Detected updatable app id: $chosenId" 'Information' 1010
        }
    }
}

# Apply exclusion filter early
if ($appIds.Count -gt 0) {
    $originalAppIds = $appIds
    $appIds = $appIds | Where-Object { $ExcludedIds -notcontains $_ }
    # Log ALL apps from exclusion list (regardless of whether they were detected for upgrade this run)
    Log-Event ("Excluded following apps via exclusion list: {0}" -f ($ExcludedIds -join ', ')) 'Information' 1007
}

if ($appIds.Count -eq 0) {
    Log-Event 'No updatable app IDs after exclusion.' 'Information' 1001
    Set-Content -Path $detectFile -Value "Winget update run $(Get-Date -Format s): No upgrades (after exclusion)." -Force
    Log-Event "Detection file written $detectFile" 'Information' 1410
    Log-Event "Script completed." 'Information' 1999
    exit 0
}

$successIds = @()
$failedIds  = @()
$skippedIds = @()

foreach ($appid in $appIds) {
    if ($appid -eq 'Microsoft.AppInstaller') {
        Log-Event "Skipping $appid (self-update not attempted)." 'Information' 1006
        $skippedIds += $appid
        continue
    }
    Log-Event "Upgrading $appid..." 'Information' 1100
    try {
        $proc = Start-Process -FilePath $wingetExe -ArgumentList @(
            'upgrade','--id',$appid,
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity',
            '--force'
        ) -PassThru -Wait
        if ($proc.ExitCode -eq 0) {
            Log-Event "SUCCESS: $appid" 'Information' 1003
            $successIds += $appid
        } else {
            Log-Event "FAILED: $appid ExitCode=$($proc.ExitCode)" 'Error' 1202
            $failedIds += $appid
        }
    } catch {
        Log-Event "EXCEPTION: $appid : $($_.Exception.Message)" 'Error' 1205
        $failedIds += $appid
    }
}

Set-Content -Path $detectFile -Value ("Winget update run {0}. Success={1} Failed={2} Skipped={3}" -f (Get-Date -Format s), $successIds.Count, $failedIds.Count, $skippedIds.Count) -Force
Log-Event "Detection file written $detectFile" 'Information' 1410

$successList = ($successIds -join ', ')
$failedList  = ($failedIds -join ', ')
$skippedList = ($skippedIds -join ', ')
Log-Event ("Summary: Success=({0}) Failed=({1}) Skipped=({2})" -f $successList, $failedList, $skippedIds) 'Information' 1401

Log-Event "Script completed." 'Information' 1999
'@

Set-Content -Path $ScriptPath -Value $upgradeScriptContent -Encoding UTF8 -Force
Write-Host "Update script written to $ScriptPath" -ForegroundColor Green

# Remove ANY previous "Winget upgrade"/"Winget update" tasks (excluding current name if present)
if ($RemoveLegacy) {
    Remove-WingetUpgradeOrUpdateTasks -CurrentTaskName $TaskName
}

# Parse run time HH:MM -> DateTime
$parts = $RunTime.Split(':')
if ($parts.Count -ne 2) {
    Write-Host "Invalid RunTime format (HH:MM expected): $RunTime" -ForegroundColor Red
    exit 1
}
$hour   = [int]$parts[0]
$minute = [int]$parts[1]
$runDate = (Get-Date).Date.AddHours($hour).AddMinutes($minute)

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
$trigger   = New-ScheduledTaskTrigger -Daily -At $runDate
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -Compatibility Win8

$taskObj = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -InputObject $taskObj | Out-Null
        Write-Host "Scheduled Task '$TaskName' updated (Compatibility=Win8; RunTime=$RunTime)." -ForegroundColor Green
    } else {
        Register-ScheduledTask -TaskName $TaskName -InputObject $taskObj | Out-Null
        Write-Host "Scheduled Task '$TaskName' created (Compatibility=Win8; RunTime=$RunTime)." -ForegroundColor Green
    }
} catch {
    Write-Host "FAILED to register task: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($ImmediateRun) {
    try {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Scheduled Task '$TaskName' started immediately." -ForegroundColor Cyan
    } catch {
        Write-Host "Could not start task immediately: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "Done."