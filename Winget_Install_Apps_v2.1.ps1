#Created 10/2025 by Pavel Mirochnitchenko MVP together with Github Copilot AI. Use this script to perform clean application installs during Autopilot or to on-onfield just by adding apps IDs. You can search IDs by using "Windget Search AppX". For troubleshooting, look into Event Viewer Application node.
#https://github.com/copilot/c/03a4a225-cc7b-4347-80bb-628c68f204b1

# PowerShell Script: Modernized for SYSTEM context (2025+)

# === 1. ENTER DESIRED APP IDs HERE ===
$AppIds = @(
    "7zip.7zip"
    "VideoLAN.VLC"
    #"Microsoft.VisualStudioCode"
    #"Google.Chrome"
)

# === 2. Set up logging ===
$logSource = "Winget App Install"
$logFile = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Winget_Installed_Apps_v2.1.log"
$detectionFile = $logFile
$logDir = Split-Path $logFile -Parent

if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

function Log-Event {
    param(
        [string]$Message,
        [string]$Type = "Information",
        [int]$EventId = 3000
    )
    try {
        Write-EventLog -LogName Application -Source $logSource -EntryType $Type -EventId $EventId -Message $Message
    } catch {}
    Add-Content -Path $logFile -Value "[$Type][$EventId][$((Get-Date).ToString('s'))] $Message"
}

# Ensure Event Log source exists
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($logSource)) {
        New-EventLog -LogName Application -Source $logSource
    }
} catch {
    $err = $_
    Write-Output ("Could not create EventLog source: " + $err)
}

# === 3. Ensure Winget download dir exists ===
$wingetDir = "C:\Intune\Winget"
if (-not (Test-Path $wingetDir)) {
    try {
        New-Item -Path $wingetDir -ItemType Directory -Force | Out-Null
        Log-Event "Created ${wingetDir} directory." "Information" 1001
    } catch {
        $err = $_
        Log-Event "Failed to create directory ${wingetDir}: $err" "Error" 1002
        exit 1
    }
} else {
    Log-Event "${wingetDir} already exists." "Information" 1003
}

# === 4. Download dependencies if missing, log each step ===
$wingetBundle   = "$wingetDir\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
$vcRedistExe    = "$wingetDir\vc_redist.x64.exe"

$downloads = @(
    @{ Path=$wingetBundle; Name="AppInstaller"; Url="https://aka.ms/getwinget" },
    @{ Path=$vcRedistExe;  Name="VC++ x64";    Url="https://aka.ms/vs/17/release/vc_redist.x64.exe" }
)

foreach ($item in $downloads) {
    if (-not (Test-Path $item.Path)) {
        Log-Event "Starting download of $($item.Name) from $($item.Url) to $($item.Path)" "Information" 1101
        try {
            Invoke-WebRequest -Uri $item.Url -OutFile $item.Path -ErrorAction Stop
            Log-Event "Successfully downloaded $($item.Name) to $($item.Path)" "Information" 1102
        } catch {
            $err = $_
            Log-Event "Failed to download $($item.Name) from $($item.Url): $err" "Error" 1103
            exit 1
        }
    } else {
        Log-Event "$($item.Name) package already exists at $($item.Path), skipping download." "Information" 1104
    }
}

# === 5. Install dependencies, log each step ===

# Install VC++ x64 Redistributable (system-wide, silent)
if (Test-Path $vcRedistExe) {
    Log-Event "Installing VC++ Redistributable from $vcRedistExe" "Information" 1200
    try {
        $proc = Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Log-Event "VC++ Redistributable installed successfully." "Information" 1201
        } else {
            Log-Event "VC++ Redistributable installer returned ExitCode $($proc.ExitCode)." "Warning" 1202
        }
    } catch {
        $err = $_
        Log-Event "VC++ Redistributable install failed: $err" "Error" 1203
    }
} else {
    Log-Event "VC++ installer not found at $vcRedistExe, skipping VC++ installation." "Warning" 1204
}

# Provision App Installer for completeness (but SYSTEM context may ignore this; log errors gracefully)
if (Test-Path $wingetBundle) {
    Log-Event "Starting provisioning of AppInstaller from $wingetBundle" "Information" 1210
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $wingetBundle -SkipLicense -ErrorAction Stop
        Log-Event "Successfully provisioned AppInstaller from $wingetBundle" "Information" 1211
    } catch {
        $err = $_
        Log-Event "Provisioning failed for AppInstaller at ${wingetBundle}: $err" "Warning" 1212
        # Continue even if it fails
    }
} else {
    Log-Event "Missing AppInstaller at $wingetBundle, skipping provisioning." "Warning" 1213
}

# Wait for provisioning to finish
Log-Event "Waiting 5 seconds for provisioning to finish..." "Information" 1301
Start-Sleep -Seconds 5

# === 6. Locate latest winget.exe ===
try {
    $winget = Get-ChildItem -Path 'C:\Program Files\WindowsApps\' -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    Log-Event "Located winget.exe at: $winget" "Information" 1401
} catch {
    $err = $_
    Log-Event "Error during winget search: $err" "Error" 1402
    $winget = $null
}

if (-not $winget -or -not (Test-Path $winget)) {
    Log-Event "winget.exe not found in WindowsApps; aborting install process." "Error" 1403
    exit 1
}

# === 7. Install each app ===
foreach ($AppId in $AppIds) {
    Log-Event "Starting install for AppID: ${AppId}" "Information" 1501
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winget
        $processInfo.Arguments = "install --id `"$AppId`" --silent --accept-package-agreements --accept-source-agreements --exact --disable-interactivity"
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($processInfo)
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        # Log all output to log file
        Add-Content -Path $logFile -Value "`n==== Install output for ${AppId} at $((Get-Date).ToString('s')) ===="
        Add-Content -Path $logFile -Value $stdOut
        Add-Content -Path $logFile -Value "`n==== Install errors for ${AppId} ===="
        Add-Content -Path $logFile -Value $stdErr

        if ($exitCode -eq 0) {
            Log-Event "Successfully installed ${AppId}. ExitCode: $exitCode" "Information" 1502
        } elseif ($exitCode -eq -1073741515) {
            Log-Event "Failed to install ${AppId}. ExitCode: $exitCode (DLL not found - missing dependencies for SYSTEM context, see https://aka.ms/winget-system-requirements)" "Error" 1599
        } else {
            Log-Event "Failed to install ${AppId}. ExitCode: $exitCode`nStdOut:`n$stdOut`nStdErr:`n$stdErr" "Error" 1503
        }
    } catch {
        $err = $_
        Log-Event ("Exception during install of ${AppId}: " + $err) "Error" 1504
    }
}

# === 8. Create/update Intune detection file ===
try {
    Set-Content -Path $detectionFile -Value "Winget install script ran at $(Get-Date -Format 's'). Apps processed: $($AppIds -join ', ')" -Force
    Log-Event "Detection file written at: $detectionFile" "Information" 1601
} catch {
    $err = $_
    Log-Event ("Failed to write detection file: " + $err) "Error" 1602
}