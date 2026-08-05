[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\CertMate",
    [string]$BackupRoot = "C:\CertMateBackups"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $BackupRoot "certmate-backup-$timestamp.zip"

$paths = @()
foreach ($item in @(".env", "data", "certificates", "config")) {
    $path = Join-Path $InstallRoot $item
    if (Test-Path $path) { $paths += $path }
}

Compress-Archive -Path $paths -DestinationPath $backup -Force
Write-Host "Backup created: $backup" -ForegroundColor Green
