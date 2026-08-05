#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallRoot = "C:\CertMate", [switch]$RemoveFiles)

Stop-Service CertMate -ErrorAction SilentlyContinue
$exe = Join-Path $InstallRoot "CertMateService.exe"
if (Test-Path $exe) {
    Push-Location $InstallRoot
    try { & $exe uninstall } finally { Pop-Location }
} else {
    sc.exe delete CertMate | Out-Null
}
if ($RemoveFiles) { Remove-Item $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "Uninstall complete." -ForegroundColor Green
