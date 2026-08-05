[CmdletBinding()]
param([string]$InstallRoot = "C:\CertMate", [int]$Port = 8000)

Write-Host "== CertMate Validation ==" -ForegroundColor Cyan
Get-Service CertMate -ErrorAction SilentlyContinue | Format-Table -AutoSize
Get-CimInstance Win32_Service -Filter "Name='CertMate'" | Select-Object Name, State, StartName, ProcessId, PathName | Format-List

try {
    $health = Invoke-WebRequest "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 15
    Write-Host "Health HTTP $($health.StatusCode)" -ForegroundColor Green
    Write-Host $health.Content
} catch {
    Write-Host "Health check failed: $($_.Exception.Message)" -ForegroundColor Red
}

try {
    $main = Invoke-WebRequest "http://localhost:$Port" -UseBasicParsing -TimeoutSec 15
    Write-Host "Main page HTTP $($main.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "Main page check failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nRecent logs:" -ForegroundColor Cyan
Get-Content "$InstallRoot\logs\*.log" -Tail 100 -ErrorAction SilentlyContinue
