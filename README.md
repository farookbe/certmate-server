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
