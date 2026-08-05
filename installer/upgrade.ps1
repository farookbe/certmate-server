#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\CertMate",
    [string]$SourceZipUrl = "https://github.com/fabriziosalmi/certmate/archive/refs/heads/main.zip"
)

Write-Host "Upgrade is intentionally conservative." -ForegroundColor Yellow
Write-Host "Before upgrade, run: .\scripts\backup.ps1" -ForegroundColor Yellow
Write-Host "Then rerun .\installer\install.ps1 without -CleanInstall to preserve .env/data/certificates." -ForegroundColor Yellow
