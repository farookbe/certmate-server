# Production Runbook

## First install

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\installer\install.ps1
```

## After install

1. Open `http://localhost:8000`.
2. Create the initial admin user.
3. Configure Azure DNS provider in the UI.
4. Add DNS-01 alias domain, for example `breeding.kiwi`.
5. Issue a test certificate.
6. Force renewal.
7. Confirm TXT cleanup.

## Backup

```powershell
.\scripts\backup.ps1
```

## Admin password reset

```powershell
.\scripts\reset-admin.ps1 -Username admin
```
