# CertMate Server - Windows Server 2022 Production Deployment

This repository contains a clean, production-ready Windows deployment wrapper for CertMate.

It does **not** contain secrets, certificates, `.env`, `settings.json`, Azure client secrets, or issued certificates.

## What this repo provides

- Zero-touch Windows Server 2022 installer
- WinSW Windows Service configuration
- Windows compatibility patches for CertMate
- DNS-01 alias checker fix for split-brain DNS environments
- Admin password reset helper
- Backup and validation scripts
- HTTPS validation helper for reverse proxy testing

## Default install path

```text
C:\CertMate
```

## Recommended production service mode

The default and recommended production service mode is:

```text
WinSW
```

This is the mode that has already worked in testing for:

- dashboard login
- Azure DNS
- DNS-01 alias to `breeding.kiwi`
- SAN certificate issuance
- forced renewal
- TXT cleanup

## Quick install

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
cd .\installer
.\install.ps1
```

Clean install:

```powershell
.\install.ps1 -CleanInstall
```

Install with custom DNS names for HTTPS verification:

```powershell
.\install.ps1 -CustomDnsNames @("certmate.example.com")
```

## Post-install validation

```powershell
.\scripts\validate.ps1
```

Manual checks:

```powershell
Get-Service CertMate
Invoke-WebRequest http://localhost:8000/health -UseBasicParsing
Invoke-WebRequest http://localhost:8000 -UseBasicParsing
```

## Production secret handling

Do not commit any production secrets.

Never commit:

```text
.env
settings.json
certificates/
data/
logs/
backups/
*.pfx
*.key
*.pem
```

Azure DNS credentials should either be entered from the CertMate UI after install or migrated later to Azure Key Vault integration.

## HTTPS model

CertMate should listen locally on HTTP:

```text
http://127.0.0.1:8000
```

Use IIS, Caddy, or Nginx as the public HTTPS endpoint:

```text
Browser -> HTTPS 443 -> Reverse Proxy -> HTTP 127.0.0.1:8000 -> CertMate
```

Validate HTTPS after reverse proxy setup:

```powershell
.\scripts\verify-https.ps1 -HostName certmate.example.com -CheckLocalBackend
```

## Repo layout

```text
installer/
  install.ps1
  upgrade.ps1
  uninstall.ps1
  CertMateInstaller.iss   ; Inno Setup script to build single-exe installer (compile on Windows)

scripts/
  validate.ps1
  backup.ps1
  reset-admin.ps1
  set-custom-dns-names.ps1
  verify-https.ps1

deploy/
  winsw/
    CertMateService.xml.template

config/
  certmate.env.template
  custom-dns-names.example.txt

docs/
  production-runbook.md
  troubleshooting.md
  security-notes.md
```

Single-file installer (Inno Setup)

This branch includes an Inno Setup script: installer/CertMateInstaller.iss. Compile this on a Windows machine with Inno Setup (ISCC) to produce a single EXE. The generated installer will extract the repository to the chosen Program Files folder and then run the bundled installer PowerShell script (installer/install.ps1) with elevated privileges to perform the full CertMate installation and register the Windows service (WinSW).

Notes:
- PrivilegesRequired=admin in the .iss means the installer will request elevation.
- The actual CertMate source is downloaded during installation by install.ps1; the installer EXE only bundles the wrapper and scripts to perform a zero-touch deployment.

Certificate import and download API

The installer now creates a small API module (modules/web/certificates_api.py) and auto-registers it with app.py. This provides two endpoints to manage certificates from the dashboard or via HTTP calls:

1) POST /api/certificates/import
- Accepts multipart/form-data with either:
  - 'cert' (PEM) and 'key' (PEM) files, OR
  - 'pfx' file and form field 'pfx_password' for the uploaded PFX
- The certificate is stored under the server's certificates directory as <CN> with dots replaced by underscores. Example: CN api.example.com -> api_example_com.crt and api_example_com.key
- Returns JSON {"status": "ok", "cn": "<common name>"} on success.

2) POST /api/certificates/download
- Requires form fields: 'cn' (the certificate common name), 'format' ('pfx' or 'crt'), and for 'pfx' a 'password' to protect the exported PFX.
- Returns the certificate as an attachment. The filename will be the CN with dots replaced by underscores, e.g. api_example_com.pfx.
- PFX export requires the caller to supply the password (the server will not store PFX passwords).

Security considerations

- PFX exports require a password. The implementation requires the caller to provide the password at download time.
- Private keys are stored on disk under the CertMate install path; protect the install directory and limit access to administrators.
- This branch installs the Python cryptography package to support safe PFX handling.

Examples (curl):

Import PEM cert+key:

```bash
curl -F "cert=@./site.crt" -F "key=@./site.key" https://certmate-host/api/certificates/import
```

Import a pfx (server will require the pfx password):

```bash
curl -F "pfx=@./site.pfx" -F "pfx_password=secret" https://certmate-host/api/certificates/import
```

Download PFX (POST):

```bash
curl -X POST -F "cn=api.example.com" -F "format=pfx" -F "password=exportPass" https://certmate-host/api/certificates/download -o api_example_com.pfx
```

Please review and tell me if you want a different installer behaviour (MSI instead), additional CA integrations (Venafi/DigiCert), or a UI change in the dashboard to surface these import/export actions.