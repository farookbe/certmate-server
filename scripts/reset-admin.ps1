[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\CertMate",
    [string]$Username = "admin"
)

$ErrorActionPreference = "Stop"
$settings = Join-Path $InstallRoot "data\settings.json"
$python = Join-Path $InstallRoot "venv\Scripts\python.exe"
if (!(Test-Path $settings)) { throw "settings.json not found: $settings" }
if (!(Test-Path $python)) { throw "Python venv not found: $python" }

$password = Read-Host "Enter new password for user '$Username'" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

$script = @'
import json, sys, bcrypt
settings_path, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path, 'r', encoding='utf-8') as f:
    data = json.load(f)
users = data.setdefault('users', {})
user = users.setdefault(username, {})
user['password_hash'] = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
user['role'] = user.get('role') or 'admin'
user['enabled'] = True
data['local_auth_enabled'] = True
with open(settings_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
print('Password reset complete for', username)
'@
$tmp = Join-Path $env:TEMP "certmate-reset-admin.py"
Set-Content $tmp $script -Encoding UTF8
& $python $tmp $settings $Username $plain
Remove-Item $tmp -Force
Restart-Service CertMate -ErrorAction SilentlyContinue
Write-Host "Password reset complete. Login username: $Username" -ForegroundColor Green
