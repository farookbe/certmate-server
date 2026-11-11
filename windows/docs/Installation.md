# CertMate Windows - Installation Guide

Target: **Windows Server 2025 x64**.

This guide covers a clean install from the signed `CertMate-Windows-v<upstream>-r<windows-revision>-x64.exe` installer produced by `Build-Release.ps1`.

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Windows Server 2025 x64 | The target platform. |
| .NET 8 runtime | Shipped by the installer (self-contained); no separate install needed. |
| Administrator rights | The installer requires an elevated shell. |
| Port 8000 (or your `CERTMATE_PORT`) free | The service binds to `127.0.0.1` by default. |
| 200 MB free disk under `C:\Program Files` and `C:\ProgramData` | Plus the upstream app tree and embedded Python. |

## 2. Verify the installer (integrity + signature)

```powershell
# 1. Confirm the SHA-256 against the release page.
(Get-FileHash .\CertMate-Windows-v2.55.1-r2-x64.exe -Algorithm SHA256).Hash

# 2. Confirm the Authenticode signature (the release pipeline signs and
#    timestamps the .exe with SHA-256). The certificate chain must resolve
#    to a trusted publisher.
Get-AuthenticodeSignature .\CertMate-Windows-v2.55.1-r2-x64.exe
```

If the signature does not verify against your trusted publisher, stop. The
binary is not the one the release pipeline produced.

## 3. Run the installer

```powershell
# From an elevated shell.
.\CertMate-Windows-v2.55.1-r2-x64.exe
```

The wizard:

1. Runs a **pre-flight check** (must be running as administrator; writes to the installer log) and stops with a clear message if the elevation or data-directory precondition is not met.
2. Copies the self-contained .NET service host (runtime included - no separate .NET install step), the PFX + update engine tools, embedded Python 3.12 x64, the patched app tree, and the relocatable certbot launcher to `C:\Program Files\CertMate`.
3. Creates the mutable tree under `C:\ProgramData\CertMate` with a restrictive ACL (SYSTEM, Administrators, and `NT SERVICE\CertMate` only).
4. Runs `CertMateService.exe init-secrets` to generate and DPAPI-wrap the persistent secrets bundle (API bearer token, session secret, encrypted backup passphrase, and the initial administrator bootstrap).
5. Registers the Windows service `CertMate` as `Automatic (Delayed Start)` with a recovery policy (restart at 5s / 30s / 30s, reset daily). `sc create` is idempotent, so re-running the installer over an existing install (an in-place upgrade) is safe.
6. Registers the Event Log source so Event Viewer can find CertMate lines.
7. Starts the service and runs the health/ready probe. If the probe fails, the installer rolls back to the previous version (on an upgrade) or stops with a clear message (on a clean install).
8. Runs a **post-install validation** and writes to the installer log: confirms the service is registered, the host executable is present, and the engine tools shipped. A validation dialog with the next-step commands is shown on success; on failure the dialog points at the log path.

The installer is **idempotent**: re-running it over an existing install is an in-place upgrade (binaries replaced, ProgramData preserved). Uninstalling removes the binaries and the service but **does not** delete `C:\ProgramData\CertMate`.

The installer does **not** create the first administrator for you. That is the next step, and it is the security boundary for remote access.

## 4. Create the initial administrator

Open the local dashboard on the machine:

```
http://127.0.0.1:8000/
```

You are in setup mode: every request is served as admin until you complete setup. Complete it now:

1. Create the initial local administrator (username + strong password).
2. Enable local authentication.
3. Configure at least one DNS provider or a private CA.

Until step 1 is done, do **not** expose the service to the network. The default bind is loopback-only for exactly this reason.

## 5. Confirm the service is healthy

```powershell
# Event Log: look for the most recent Information entries from the
# "CertMate" source.
Get-WinEvent -LogName Application -Source CertMate -Newest 10

# Health endpoints (loopback only, by default):
Invoke-RestMethod http://127.0.0.1:8000/health
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

`/health/ready` returns 503 when the certbot readiness probe or the scheduler has not succeeded. Read the `error` field; the release spec requires a broken certbot to keep the instance out of rotation, not to silently report ready.

## 6. (Optional) enable remote access

To serve the dashboard over the network you must:

1. Put TLS in front of the service (a reverse proxy on 443, or a self-signed certificate bound to the machine name).
2. Terminate the loopback bind: run the service with `CERTMATE_HOST=0.0.0.0` (or a specific external interface) and `PREFERRED_URL_SCHEME=https`.
3. **Before** exposing it, create the initial administrator. The spec requires that remote access is not permitted until authentication and TLS are configured and the recovery administrator exists.
4. Optionally enable Microsoft Entra ID / OIDC SSO and map the `Group` claim to a CertMate role (viewer / operator / admin) under Settings → SSO → Group Mapping. Keep the local recovery administrator active even when SSO is enabled.

The local recovery administrator is the escape hatch: it always works even if SSO is misconfigured.

## 7. Export a certificate as PFX

The PFX export is a first-class, password-protected operation available two ways, both calling the same `cryptography` code path (leaf + full chain + private key, `BestAvailableEncryption`):

- **On the machine / from the dashboard.** The upstream dashboard's "Export PFX" button for a managed certificate POSTs to the local `GET /pfx/export/<domain>?password=<…>` route (registered by the launcher, operator-scoped). The password must meet the policy (≥12 characters, at least 3 of 4 character classes); the blob is streamed in-memory and never written to disk by that route.
- **From the operator console** (always available, no service needed):

  ```powershell
  # Password from a file (preferred - the value never appears on the command line):
  "Ab1!Ab1!Ab1!Wx" | Out-File .\pfx-password.txt -Encoding ascii
  & "C:\Program Files\CertMate\bin\CertMateService.exe" export-pfx example.com `
      --password-file .\pfx-password.txt

  # Password from an environment variable:
  $env:CERTMATE_PFX_PASSWORD = "Ab1!Ab1!Ab1!Wx"
  & "C:\Program Files\CertMate\bin\CertMateService.exe" export-pfx example.com

  # Interactive prompt (if no --password-file / --password-env is given):
  & "C:\Program Files\CertMate\bin\CertMateService.exe" export-pfx example.com
  ```

  The output is a PKCS#12 file at `CWD\example.com.pfx` (override with `--out <path>`). It contains the leaf certificate, the intermediate chain, and the private key, all wrapped in `BestAvailableEncryption`.

The PFX password policy is enforced on **every** path: a weak or blank password is refused so an unencrypted bundle cannot be minted.

## 8. Uninstall

```powershell
# Preserve ProgramData (the default behaviour of the uninstaller):
& "C:\Program Files\CertMate\Uninstall-CertMate.exe"
```

The uninstall removes the binaries and the service but **does not** delete `C:\ProgramData\CertMate`. That tree holds your settings, certificates, private keys, the audit chain, and the DPAPI bundle, so it is preserved by default. Delete it explicitly only when you intend to wipe the instance:

```powershell
Remove-Item -Recurse -Force "C:\ProgramData\CertMate"
```
