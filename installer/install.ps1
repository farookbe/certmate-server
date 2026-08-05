#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\CertMate",
    [string]$SourceZipUrl = "https://github.com/fabriziosalmi/certmate/archive/refs/heads/main.zip",
    [string]$PythonInstallerUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe",
    [string]$WinSWUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe",
    [int]$Port = 8000,
    [string]$HostAddress = "0.0.0.0",
    [string[]]$CustomDnsNames = @(),
    [switch]$CleanInstall,
    [switch]$SkipServiceStart
)


$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell window: Run as Administrator."
    }
}

function Set-SafeTls {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}

function Invoke-Download {
    param([Parameter(Mandatory=$true)][string]$Uri, [Parameter(Mandatory=$true)][string]$OutFile)
    $parent = Split-Path -Parent $OutFile
    if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers @{ "User-Agent" = "CertMate-Windows-Installer" }
    if (!(Test-Path $OutFile) -or ((Get-Item $OutFile).Length -lt 1024)) { throw "Download failed or invalid file: $Uri" }
}

function New-RandomString { param([int]$Length = 64) return -join ((48..57)+(65..90)+(97..122) | Get-Random -Count $Length | ForEach-Object {[char]$_}) }

function Get-PythonExecutable {
    $candidates = @("$env:ProgramFiles\Python311\python.exe", "$env:LocalAppData\Programs\Python\Python311\python.exe")
    foreach ($candidate in $candidates) { if (Test-Path $candidate) { return $candidate } }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = & $cmd.Source --version 2>&1
        if ($version -match "Python 3\.(11|12)\.") { return $cmd.Source }
    }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $path = & $py.Source -3.11 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $path)) { return $path }
        } catch { }
    }
    return $null
}

function Grant-CertMatePermissions {
    param([string]$Path)
    $currentUser = "$($env:USERDOMAIN)\$($env:USERNAME)"
    takeown /F $Path /R /D Y | Out-Null
    icacls $Path /inheritance:e /T | Out-Null
    icacls $Path /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${currentUser}:(OI)(CI)F" /T | Out-Null
    attrib -R "$Path\*" /S /D 2>$null
}

function Write-CertMateEnv {
    param([string]$Root, [int]$Port, [string]$HostAddress)
    $envFile = Join-Path $Root ".env"
    if (!(Test-Path $envFile)) {
        @"
HOST=$HostAddress
PORT=$Port
API_BEARER_TOKEN=$(New-RandomString 64)
SECRET_KEY=$(New-RandomString 64)
# Add DNS provider credentials in the CertMate UI after setup.
"@ | Set-Content $envFile -Encoding ASCII
        Write-Ok "Created .env"
    } else {
        Write-Ok ".env exists; preserving existing file"
    }
}

function Save-CustomDnsNames {
    param([string]$Root, [string[]]$Names)
    New-Item -ItemType Directory -Path (Join-Path $Root "config") -Force | Out-Null
    $file = Join-Path $Root "config\custom-dns-names.txt"
    $clean = @($Names) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToLower() } | Select-Object -Unique
    if ($clean) { $clean | Set-Content $file -Encoding ASCII; Write-Ok "Saved custom DNS names to $file" }
    else { if (!(Test-Path $file)) { New-Item -ItemType File -Path $file -Force | Out-Null } }
}

function Patch-CertMateWindows {
    param([string]$Root, [string]$VenvPython)
    Write-Step "Applying Windows compatibility patches"

    $structuredLogging = Join-Path $Root "modules\core\structured_logging.py"
    if (Test-Path $structuredLogging) {
        Copy-Item $structuredLogging "$structuredLogging.bak-win-$(Get-Date -Format yyyyMMddHHmmss)" -Force
        $content = Get-Content $structuredLogging -Raw
        if ($content -match 'os\.uname\(\)\.nodename') {
            $content = $content -replace 'os\.uname\(\)\.nodename if include_hostname else None', 'socket.gethostname() if include_hostname else None'
            if ($content -notmatch 'import socket') { $content = $content -replace 'import os', "import os`r`nimport socket" }
            Set-Content $structuredLogging $content -Encoding UTF8
        }
    }

    $fileOperations = Join-Path $Root "modules\core\file_operations.py"
    if (Test-Path $fileOperations) {
        Copy-Item $fileOperations "$fileOperations.bak-win-$(Get-Date -Format yyyyMMddHHmmss)" -Force
        $content = Get-Content $fileOperations -Raw
        if ($content -match '(?m)^import fcntl\s*$') {
            $replacement = @'
if os.name == "nt":
    class _FcntlCompat:
        LOCK_SH = 1
        LOCK_EX = 2
        LOCK_NB = 4
        LOCK_UN = 8
        @staticmethod
        def flock(file_or_fd, operation):
            return None
    fcntl = _FcntlCompat()
else:
    import fcntl
'@
            $content = $content -replace '(?m)^import fcntl\s*$', '__FCNTL_COMPAT_BLOCK__'
            $content = $content.Replace('__FCNTL_COMPAT_BLOCK__', $replacement)
        }
        $content = $content.Replace('temp_file.rename(file_path)', 'os.replace(str(temp_file), str(file_path))')
        Set-Content $fileOperations $content -Encoding UTF8
    }

    $appPy = Join-Path $Root "app.py"
    if (Test-Path $appPy) {
        Copy-Item $appPy "$appPy.bak-win-$(Get-Date -Format yyyyMMddHHmmss)" -Force
        $content = Get-Content $appPy -Raw
        $content = $content -replace 'print\(f".*Starting CertMate v\{__version__\} on \{args\.host\}:\{args\.port\}"\)', 'print(f"Starting CertMate v{__version__} on {args.host}:{args.port}")'
        $content = $content -replace 'print\(f".*Debug mode: \{[^}]+\}"\)', 'print(f"Debug mode: {args.debug}")'
        Set-Content $appPy $content -Encoding UTF8
    }

    $certificatesPy = Join-Path $Root "modules\core\certificates.py"
    if (Test-Path $certificatesPy) {
        Copy-Item $certificatesPy "$certificatesPy.bak-win-$(Get-Date -Format yyyyMMddHHmmss)" -Force
        $content = Get-Content $certificatesPy -Raw
        $patternResolve = '(?s)    @classmethod\r?\n    def _resolve_cname\(cls, source\):.*?\r?\n    def check_dns_alias_records\(self, domain, domain_alias, san_domains=None\):'
        $replacementResolve = @'
    @classmethod
    def _resolve_cname(cls, source):
        source = cls._normalize_cname_target(source)
        try:
            import requests
            import certifi
            response = requests.get(
                'https://cloudflare-dns.com/dns-query',
                params={'name': source, 'type': 'CNAME'},
                headers={'accept': 'application/dns-json'},
                timeout=10,
                verify=certifi.where(),
            )
            response.raise_for_status()
            payload = response.json()
        except requests.exceptions.RequestException as e:
            raise RuntimeError(f'DNS query failed: {e}') from e
        except ValueError as e:
            raise RuntimeError(f'DNS query failed: invalid JSON response: {e}') from e

        answers = payload.get('Answer') or []
        return [
            answer.get('data', '').strip()
            for answer in answers
            if answer.get('type') == 5 and answer.get('data')
        ]

    def check_dns_alias_records(self, domain, domain_alias, san_domains=None):
'@
        if ($content -match $patternResolve) { $content = [System.Text.RegularExpressions.Regex]::Replace($content, $patternResolve, $replacementResolve) }

        $patternHook = '(?s)        auth_hook = \(\r?\n            f"\{shlex\.quote\(sys\.executable\)\}.*?        cleanup_hook = \(\r?\n            f"\{shlex\.quote\(sys\.executable\)\}.*?\r?\n        \)'
        $replacementHook = @'
        if os.name == 'nt':
            import subprocess as _subprocess
            auth_hook = _subprocess.list2cmdline([
                sys.executable,
                str(hook_script),
                '--config',
                str(hook_config),
                '--action',
                'auth',
            ])
            cleanup_hook = _subprocess.list2cmdline([
                sys.executable,
                str(hook_script),
                '--config',
                str(hook_config),
                '--action',
                'cleanup',
            ])
        else:
            auth_hook = (
                f"{shlex.quote(sys.executable)} {shlex.quote(str(hook_script))} "
                f"--config {shlex.quote(str(hook_config))} --action auth"
            )
            cleanup_hook = (
                f"{shlex.quote(sys.executable)} {shlex.quote(str(hook_script))} "
                f"--config {shlex.quote(str(hook_config))} --action cleanup"
            )
'@
        if ($content -match $patternHook) { $content = [System.Text.RegularExpressions.Regex]::Replace($content, $patternHook, $replacementHook) }
        Set-Content $certificatesPy $content -Encoding UTF8
    }

    $sitePackages = & $VenvPython -S -c "import sysconfig; print(sysconfig.get_paths()['purelib'])"
    $shim = @'
import os, sys, types, socket
if os.name == "nt":
    if not hasattr(os, "uname"):
        class _UnameResult(tuple):
            __slots__=()
            def __new__(cls,a,b,c,d,e): return tuple.__new__(cls,(a,b,c,d,e))
            @property
            def sysname(self): return self[0]
            @property
            def nodename(self): return self[1]
            @property
            def release(self): return self[2]
            @property
            def version(self): return self[3]
            @property
            def machine(self): return self[4]
        def _windows_uname():
            try:
                w=sys.getwindowsversion(); rel=str(w.major); ver="%s.%s.%s"%(w.major,w.minor,w.build)
            except Exception:
                rel="Windows"; ver="Windows"
            return _UnameResult("Windows",socket.gethostname(),rel,ver,os.environ.get("PROCESSOR_ARCHITECTURE","AMD64"))
        os.uname=_windows_uname
    try:
        import fcntl
    except Exception:
        fcntl_mock=types.ModuleType("fcntl"); fcntl_mock.LOCK_EX=1; fcntl_mock.LOCK_SH=1; fcntl_mock.LOCK_NB=2; fcntl_mock.LOCK_UN=4
        def flock(file_or_fd, operation): return None
        fcntl_mock.flock=flock; sys.modules["fcntl"]=fcntl_mock
'@
    foreach ($target in @((Join-Path $Root "venv\sitecustomize.py"), (Join-Path $sitePackages "sitecustomize.py"))) {
        $parent = Split-Path -Parent $target
        if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content $target $shim -Encoding UTF8
    }
    Write-Ok "Windows patches applied"
}


Assert-Admin
Set-SafeTls
$ServiceName = "CertMate"
$TempRoot = Join-Path $env:TEMP "certmate-install"
$RepoZip = Join-Path $TempRoot "certmate.zip"
$ExtractRoot = Join-Path $TempRoot "repo"
$PythonInstaller = Join-Path $TempRoot "python-3.11.9-amd64.exe"
$VenvRoot = Join-Path $InstallRoot "venv"
$VenvPython = Join-Path $VenvRoot "Scripts\python.exe"
$ServiceExe = Join-Path $InstallRoot "CertMateService.exe"

Write-Step "Preparing installation root: $InstallRoot"
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

if ($CleanInstall -and (Test-Path $InstallRoot)) {
    Stop-Service $ServiceName -ErrorAction SilentlyContinue
    if (Test-Path $ServiceExe) { try { & $ServiceExe uninstall | Out-Null } catch { } }
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallRoot*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

Write-Step "Checking Python"
$PythonExe = Get-PythonExecutable
if (-not $PythonExe) {
    Invoke-Download -Uri $PythonInstallerUrl -OutFile $PythonInstaller
    Start-Process -FilePath $PythonInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1" -Wait
    $PythonExe = Get-PythonExecutable
}
if (-not $PythonExe) { throw "Python 3.11/3.12 not found after installation." }
Write-Ok "Using Python: $PythonExe"

Write-Step "Downloading CertMate source"
Invoke-Download -Uri $SourceZipUrl -OutFile $RepoZip
if (Test-Path $ExtractRoot) { Remove-Item $ExtractRoot -Recurse -Force }
New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
Expand-Archive -Path $RepoZip -DestinationPath $ExtractRoot -Force
$Source = Get-ChildItem $ExtractRoot -Directory | Select-Object -First 1
if (-not $Source) { throw "Could not find extracted CertMate source folder." }

Write-Step "Copying CertMate files"
$savedEnv = $null
if (Test-Path (Join-Path $InstallRoot ".env")) { $savedEnv = Join-Path $TempRoot ".env.backup"; Copy-Item (Join-Path $InstallRoot ".env") $savedEnv -Force }
Get-ChildItem $InstallRoot -Force | Where-Object { $_.Name -notin @("venv","data","certificates","backups","logs","letsencrypt","config","ssl") } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $Source.FullName "*") -Destination $InstallRoot -Recurse -Force
if ($savedEnv) { Copy-Item $savedEnv (Join-Path $InstallRoot ".env") -Force }
foreach ($dir in @("data","logs","backups","certificates","letsencrypt","ssl","config")) { New-Item -ItemType Directory -Path (Join-Path $InstallRoot $dir) -Force | Out-Null }
Grant-CertMatePermissions -Path $InstallRoot

Write-Step "Creating Python virtual environment"
if (!(Test-Path $VenvPython)) { & $PythonExe -m venv $VenvRoot }
if (!(Test-Path $VenvPython)) { throw "Virtual environment was not created." }

Write-Step "Installing Python dependencies"
& $VenvPython -m pip install --upgrade pip setuptools wheel
& $VenvPython -m pip install --no-cache-dir -r (Join-Path $InstallRoot "requirements.txt")
& $VenvPython -m pip install --upgrade requests certifi urllib3

Patch-CertMateWindows -Root $InstallRoot -VenvPython $VenvPython
Write-CertMateEnv -Root $InstallRoot -Port $Port -HostAddress $HostAddress
Save-CustomDnsNames -Root $InstallRoot -Names $CustomDnsNames

Write-Step "Testing Python files"
Push-Location $InstallRoot
try {
    & $VenvPython -c "import os, fcntl; print(os.uname().nodename); fcntl.flock(1, fcntl.LOCK_EX); print('compatibility test OK')"
    & $VenvPython -m py_compile .\app.py
    & $VenvPython -m py_compile .\modules\core\certificates.py
} finally { Pop-Location }

Write-Step "Installing WinSW service"
Invoke-Download -Uri $WinSWUrl -OutFile $ServiceExe
$templatePath = Join-Path $PSScriptRoot "..\deploy\winsw\CertMateService.xml.template"
$template = Get-Content $templatePath -Raw
$xml = $template.Replace("__INSTALL_ROOT__", $InstallRoot).Replace("__HOST__", $HostAddress).Replace("__PORT__", [string]$Port)
Set-Content (Join-Path $InstallRoot "CertMateService.xml") $xml -Encoding UTF8

if (Get-Service $ServiceName -ErrorAction SilentlyContinue) { Stop-Service $ServiceName -ErrorAction SilentlyContinue; & $ServiceExe uninstall | Out-Null }
Push-Location $InstallRoot
try { & $ServiceExe install } finally { Pop-Location }

$fwName = "CertMate Web Management Portal"
if (!(Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Domain,Private | Out-Null
}

if (-not $SkipServiceStart) {
    Push-Location $InstallRoot
    try { & $ServiceExe start } finally { Pop-Location }
    Start-Sleep -Seconds 8
    Get-Service $ServiceName
    try { $h = Invoke-WebRequest "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 15; Write-Ok "Health endpoint returned HTTP $($h.StatusCode)" } catch { Write-Warn "Health check failed. Check logs." }
}

Write-Host "`nCertMate production install completed." -ForegroundColor Green
Write-Host "Install root: $InstallRoot" -ForegroundColor Green
Write-Host "URL: http://localhost:$Port" -ForegroundColor Green
