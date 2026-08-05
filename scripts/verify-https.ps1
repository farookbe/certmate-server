[CmdletBinding()]
param(
    [string]$HostName,
    [string[]]$DnsNames = @(),
    [int]$HttpsPort = 443,
    [string]$InstallRoot = "C:\CertMate",
    [switch]$CheckLocalBackend,
    [int]$LocalBackendPort = 8000
)

function Pass($m){Write-Host "[PASS] $m" -ForegroundColor Green}
function Fail($m){Write-Host "[FAIL] $m" -ForegroundColor Red}
function Warn($m){Write-Host "[WARN] $m" -ForegroundColor Yellow}
function Sec($m){Write-Host "`n==> $m" -ForegroundColor Cyan}

if ($HostName) { $DnsNames = @($HostName) + $DnsNames }
$config = Join-Path $InstallRoot "config\custom-dns-names.txt"
if (!$DnsNames -and (Test-Path $config)) { $DnsNames = Get-Content $config | Where-Object { $_ -and $_.Trim() } }
$DnsNames = $DnsNames | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToLower() } | Select-Object -Unique
if (!$DnsNames) { throw "Provide -HostName or -DnsNames, or configure custom DNS names." }

$ok = $true
foreach ($name in $DnsNames) {
    Sec "Validating HTTPS for $name"
    $url = "https://$name"
    if ($HttpsPort -ne 443) { $url = "https://$name`:$HttpsPort" }

    try { Resolve-DnsName $name -ErrorAction Stop | Out-Null; Pass "DNS resolved" } catch { Fail "DNS failed: $($_.Exception.Message)"; $ok = $false; continue }
    try { $tcp = Test-NetConnection -ComputerName $name -Port $HttpsPort -WarningAction SilentlyContinue; if ($tcp.TcpTestSucceeded) { Pass "TCP $HttpsPort reachable" } else { Fail "TCP $HttpsPort not reachable"; $ok = $false } } catch { Fail "TCP test failed"; $ok = $false }
    try { $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 20; if ($r.StatusCode -eq 200) { Pass "HTTPS page HTTP 200" } else { Warn "HTTPS page HTTP $($r.StatusCode)" } } catch { Fail "HTTPS check failed: $($_.Exception.Message)"; $ok = $false }
    try { $h = Invoke-WebRequest "$url/health" -UseBasicParsing -TimeoutSec 20; if ($h.StatusCode -eq 200) { Pass "HTTPS /health HTTP 200"; Write-Host $h.Content } else { Warn "HTTPS /health HTTP $($h.StatusCode)" } } catch { Warn "HTTPS /health failed: $($_.Exception.Message)" }
}

if ($CheckLocalBackend) {
    Sec "Local backend"
    try { $b = Invoke-WebRequest "http://127.0.0.1:$LocalBackendPort/health" -UseBasicParsing -TimeoutSec 10; if ($b.StatusCode -eq 200) { Pass "Local backend healthy" } else { Warn "Local backend HTTP $($b.StatusCode)" } } catch { Fail "Local backend failed: $($_.Exception.Message)"; $ok = $false }
}

if ($ok) { Pass "HTTPS validation complete"; exit 0 } else { Fail "HTTPS validation found issues"; exit 1 }
