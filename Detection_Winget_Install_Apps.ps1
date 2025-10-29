if (Test-Path -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Winget_Installed_Apps_v2.1.log") {
    # File exists – considered compliant, do nothing
    Write-Output "File exists. No remediation needed."
    exit 0
} else {
    # File does not exist – considered non-compliant
    Write-Output "File does not exist. Remediation required."
    exit 1
}