# Created 12/2025 by Pavel Mirochnitchenko MVP together with GitHub Copilot AI.
# Purpose: Clean, unattended app installs during Autopilot or on-field by listing Winget IDs.
# Tip: Find IDs with "winget search <AppName>". Troubleshoot in Event Viewer > Application (source: "Winget App Install").
# References:
# - Winget: https://aka.ms/winget
# - SYSTEM context requirements: https://aka.ms/winget-system-requirements

# =========================
# 1) ENTER DESIRED APP IDs
# =========================
$AppIds = @(
    "7zip.7zip"
    "VideoLAN.VLC"
    # "Microsoft.VisualStudioCode"
    # "Google.Chrome"
)

# =========================
# 2) Logging
# =========================
$logSource = "Winget App Install"
$logFile   = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Winget_Installed_Apps_v2.3.log"

# Ensure log directory exists (defensive)
$logDir = Split-Path $logFile -Parent
try {
    if (Test-Path -LiteralPath $logDir -PathType Leaf) {
        Write-Output "Log path exists as a file and cannot be used as a directory: $logDir"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    }
} catch {
    Write-Output ("Failed to ensure log directory: " + $_)
    exit 1
}

function Log-Event {
    param(
        [string]$Message,
        [string]$Type = "Information",
        [int]$EventId = 3000
    )
    try {
        Write-EventLog -LogName Application -Source $logSource -EntryType $Type -EventId $EventId -Message $Message
    } catch {
        # Ignore event log write issues and always write to file
    }
    Add-Content -Path $logFile -Value "[$Type][$EventId][$((Get-Date).ToString('s'))] $Message"
}

# Ensure Event Log source exists (do before first Write-EventLog)
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($logSource)) {
        New-EventLog -LogName Application -Source $logSource
    }
} catch {
    Write-Output ("Could not create EventLog source: " + $_)
}

# =========================
# 3) Networking prerequisites
# =========================
# Ensure TLS1.2 for Invoke-WebRequest on older configurations
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Log-Event "Failed to set TLS 1.2, proceeding with defaults: $($_)" "Warning" 1010
}

# =========================
# 4) Winget download/cache dir
# =========================
$wingetDir    = "C:\Intune\Winget"
$wingetBundle = Join-Path $wingetDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
$vcRedistExe  = Join-Path $wingetDir "vc_redist.x64.exe"

# Hardened creation of C:\Intune\Winget
try {
    if (Test-Path -LiteralPath $wingetDir -PathType Leaf) {
        Log-Event "${wingetDir} exists as a file; cannot create directory structure." "Error" 1000
        exit 1
    }
    if (-not (Test-Path -LiteralPath $wingetDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($wingetDir) | Out-Null
        Log-Event "Created ${wingetDir} directory." "Information" 1001
    } else {
        Log-Event "${wingetDir} already exists." "Information" 1003
    }
} catch {
    Log-Event ("Failed to create directory ${wingetDir}: " + $_) "Error" 1002
    exit 1
}

# =========================
# 5) Retry helpers (DNS + downloads)
# =========================

# Tunables
$MaxDnsAttempts               = 8    # total DNS tries per host
$InitialDnsBackoffSec         = 5    # first wait after a DNS failure
$MaxDownloadAttempts          = 6    # total download tries per file
$InitialDownloadBackoffSec    = 5
$BackoffFactor                = 1.7  # exponential factor
$JitterPercent                = 0.30 # +/- jitter as a fraction of base delay

function Get-BackoffDelaySec {
    param(
        [int]$AttemptNumber,         # 1-based
        [int]$InitialSeconds,
        [double]$Factor,
        [double]$JitterFraction
    )
    $base = [math]::Ceiling($InitialSeconds * [math]::Pow($Factor, ($AttemptNumber - 1)))
    $jitterMax = [math]::Max([int]([math]::Round($base * $JitterFraction)), 1)
    $jitter = Get-Random -Minimum 0 -Maximum $jitterMax
    return ($base + $jitter)
}

function Resolve-HostWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$DnsHost
    )
    for ($i = 1; $i -le $MaxDnsAttempts; $i++) {
        try {
            [void][System.Net.Dns]::GetHostAddresses($DnsHost)
            if ($i -gt 1) {
                Log-Event "DNS resolved ${DnsHost} on attempt ${i}." "Information" 1052
            }
            return $true
        } catch {
            $msg = $_.Exception.Message
            Log-Event "DNS resolve failed for ${DnsHost} (attempt ${i}/${MaxDnsAttempts}): ${msg}" "Warning" 1051
            if ($i -ge $MaxDnsAttempts) { throw }
            $delay = Get-BackoffDelaySec -AttemptNumber ($i) -InitialSeconds $InitialDnsBackoffSec -Factor $BackoffFactor -JitterFraction $JitterPercent
            Log-Event "Retrying DNS for ${DnsHost} in ${delay}s..." "Information" 1053
            Start-Sleep -Seconds $delay
        }
    }
}

function Ensure-ParentDir {
    param([Parameter(Mandatory=$true)][string]$FilePath)
    $parent = Split-Path -Parent $FilePath
    if (-not $parent) { return }
    if (Test-Path -LiteralPath $parent -PathType Leaf) {
        throw "Path exists as a file and cannot be used as a directory: ${parent}"
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        Log-Event "Created download parent dir: ${parent}" "Information" 1109
    }
}

function Download-FileWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    $dnsHost = ([uri]$Url).Host

    # DNS resolve with retries first
    Resolve-HostWithRetry -DnsHost $dnsHost | Out-Null

    for ($i = 1; $i -le $MaxDownloadAttempts; $i++) {
        try {
            Ensure-ParentDir -FilePath $Destination

            # Prefer Invoke-WebRequest, fallback to BITS if available and IWR fails in this attempt
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            } catch {
                if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                    Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "Winget deps download" -ErrorAction Stop
                } else {
                    throw
                }
            }

            if (Test-Path -LiteralPath $Destination) {
                $size = (Get-Item -LiteralPath $Destination).Length
                if ($size -gt 0) {
                    if ($i -gt 1) {
                        Log-Event "Downloaded ${Url} successfully on attempt ${i}." "Information" 1112
                    }
                    return $true
                }
            }
            throw "Downloaded file is missing or empty after attempt ${i}."
        } catch {
            $msg = $_.Exception.Message
            Log-Event "Download failed (${Url}) attempt ${i}/${MaxDownloadAttempts}: ${msg}" "Warning" 1113
            if ($i -ge $MaxDownloadAttempts) { throw }
            $delay = Get-BackoffDelaySec -AttemptNumber ($i) -InitialSeconds $InitialDownloadBackoffSec -Factor $BackoffFactor -JitterFraction $JitterPercent
            Log-Event "Retrying download in ${delay}s..." "Information" 1115
            Start-Sleep -Seconds $delay
        }
    }
}

# =========================
# 6) Download dependencies (with retries)
# =========================
$downloads = @(
    @{ Path=$wingetBundle; Name="App Installer (winget) bundle"; Url="https://aka.ms/getwinget" },
    @{ Path=$vcRedistExe;  Name="VC++ x64 Redistributable";     Url="https://aka.ms/vs/17/release/vc_redist.x64.exe" }
)

foreach ($item in $downloads) {
    if (-not (Test-Path -LiteralPath $item.Path)) {
        Log-Event "Downloading $($item.Name) from $($item.Url) to $($item.Path)" "Information" 1111
        try {
            Download-FileWithRetry -Url $item.Url -Destination $item.Path | Out-Null
            Log-Event "Downloaded $($item.Name) to $($item.Path)" "Information" 1116
        } catch {
            Log-Event ("Failed to download $($item.Name) from $($item.Url): " + $_.Exception.Message) "Error" 1117
            exit 1
        }
    } else {
        Log-Event "$($item.Name) already cached at $($item.Path); skipping download." "Information" 1114
    }
}

# =========================
# 7) Install dependencies
# =========================
# VC++ x64 Redistributable (system-wide, silent)
if (Test-Path $vcRedistExe) {
    Log-Event "Installing VC++ Redistributable from ${vcRedistExe}" "Information" 1200
    try {
        $proc = Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Log-Event "VC++ Redistributable installed successfully." "Information" 1201
        } else {
            Log-Event "VC++ Redistributable installer returned ExitCode $($proc.ExitCode)." "Warning" 1202
        }
    } catch {
        Log-Event ("VC++ Redistributable install failed: " + $_) "Error" 1203
    }
} else {
    Log-Event "VC++ installer not found at ${vcRedistExe}; skipping VC++ installation." "Warning" 1204
}

# Provision App Installer (stages package and provisions for future users)
if (Test-Path $wingetBundle) {
    Log-Event "Provisioning App Installer from ${wingetBundle}" "Information" 1210
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $wingetBundle -SkipLicense -ErrorAction Stop | Out-Null
        Log-Event "Provisioned App Installer successfully." "Information" 1211
    } catch {
        Log-Event ("Provisioning failed for App Installer at ${wingetBundle}: " + $_) "Warning" 1212
        # Continue even if it fails; winget might already be in-box on recent Windows
    }
} else {
    Log-Event "App Installer bundle missing at ${wingetBundle}; skipping provisioning." "Warning" 1213
}

Log-Event "Waiting 5 seconds for provisioning to settle..." "Information" 1301
Start-Sleep -Seconds 5

# =========================
# 8) Locate latest winget.exe
# =========================
$winget = $null

try {
    $appx = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller | Sort-Object Version -Descending | Select-Object -First 1
    if ($appx -and $appx.InstallLocation) {
        $candidate = Join-Path $appx.InstallLocation "winget.exe"
        if (Test-Path $candidate) {
            $winget = $candidate
        }
    }
} catch {
    Log-Event ("Get-AppxPackage lookup failed: " + $_) "Warning" 1400
}

if (-not $winget) {
    try {
        $winget = Get-ChildItem -Path 'C:\Program Files\WindowsApps\' -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    } catch {
        Log-Event ("Error during recursive winget search: " + $_) "Error" 1401
    }
}

if (-not $winget -or -not (Test-Path $winget)) {
    Log-Event "winget.exe not found; aborting." "Error" 1403
    exit 1
}

Log-Event "Using winget at: ${winget}" "Information" 1404

# Log winget version and update sources
try {
    $verInfo = & $winget --version 2>&1
    Log-Event "winget version: $verInfo" "Information" 1410
} catch {
    Log-Event ("Unable to query winget version: " + $_) "Warning" 1411
}
try {
    $srcUpdate = & $winget source update --disable-interactivity 2>&1
    Log-Event "winget source update output:`n$srcUpdate" "Information" 1412
} catch {
    Log-Event ("winget source update failed: " + $_) "Warning" 1413
}

# =========================
# 9) Install each app
# =========================
foreach ($AppId in $AppIds) {
    Log-Event "Starting install for AppID: ${AppId}" "Information" 1501
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winget
        # --scope machine installs per-device when supported. --source winget avoids MS Store unless needed.
        $processInfo.Arguments = "install --id `"$AppId`" --source winget --silent --accept-package-agreements --accept-source-agreements --exact --scope machine --disable-interactivity"
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError  = $true
        $processInfo.UseShellExecute        = $false

        $proc   = [System.Diagnostics.Process]::Start($processInfo)
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        Add-Content -Path $logFile -Value "`n==== Install output for ${AppId} at $((Get-Date).ToString('s')) ===="
        Add-Content -Path $logFile -Value $stdOut
        Add-Content -Path $logFile -Value "`n==== Install errors for ${AppId} ===="
        Add-Content -Path $logFile -Value $stdErr

        if ($exitCode -eq 0) {
            Log-Event "Successfully installed ${AppId}. ExitCode: ${exitCode}" "Information" 1502
        } elseif ($exitCode -eq -1073741515) {
            Log-Event "Failed to install ${AppId}. ExitCode: ${exitCode} (DLL not found - missing dependencies for SYSTEM context; see https://aka.ms/winget-system-requirements)" "Error" 1599
        } else {
            Log-Event "Failed to install ${AppId}. ExitCode: ${exitCode}`nStdOut:`n$stdOut`nStdErr:`n$stdErr" "Error" 1503
        }
    } catch {
        Log-Event ("Exception during install of ${AppId}: " + $_) "Error" 1504
    }
}