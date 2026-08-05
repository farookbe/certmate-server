[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\CertMate",
    [string[]]$DnsNames,
    [switch]$Append,
    [switch]$List,
    [switch]$TestDns
)

$file = Join-Path $InstallRoot "config\custom-dns-names.txt"
New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null

if ($List) {
    if (Test-Path $file) { Get-Content $file } else { Write-Host "No custom DNS names configured." }
    return
}

$current = @()
if ($Append -and (Test-Path $file)) { $current = Get-Content $file }
$clean = @($current + $DnsNames) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToLower() } | Select-Object -Unique
$clean | Set-Content $file -Encoding ASCII
Write-Host "Saved custom DNS names to $file" -ForegroundColor Green
$clean | ForEach-Object { Write-Host " - $_" }

if ($TestDns) {
    foreach ($name in $clean) {
        try {
            $result = Resolve-DnsName $name -ErrorAction Stop
            $ips = $result | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique
            Write-Host "[PASS] $name -> $($ips -join ', ')" -ForegroundColor Green
        } catch {
            Write-Host "[FAIL] $name DNS lookup failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
