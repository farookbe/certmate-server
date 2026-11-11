from __future__ import annotations

import argparse
import getpass
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# --- cryptography (the ACME stack dependency; already shipped in the
#     wheelhouse / embedded python). Imported lazily so a missing dependency
#     surfaces a clean error rather than an import crash.
try:
    from cryptography.hazmat.primitives.serialization import (
        BestAvailableEncryption,
        pkcs12,
        load_pem_private_key,
    )
    from cryptography.x509 import load_pem_x509_certificates
    _HAS_CRYPTO = True
    _CRYPTO_IMPORT_ERROR = ""
except Exception as _e:  # pragma: no cover - exercised only when absent
    _HAS_CRYPTO = False
    _CRYPTO_IMPORT_ERROR = str(_e)

# Default CertMate install layout (mirrors HostConfig.cs).
DEFAULT_CERT_DIR = r"C:\ProgramData\CertMate\certificates"

# Password policy: >=12 chars, at least 3 of 4 character classes. This is the
# same policy the web blueprint enforces so an operator cannot mint an
# unencrypted bundle through either path.
MIN_PASSWORD_LEN = 12
MIN_PASSWORD_CLASSES = 3


def password_meets_policy(raw: str) -> bool:
    """A PFX password must be at least 12 characters with >=3 of the four
    character classes."""
    if not raw or len(raw) < MIN_PASSWORD_LEN:
        return False
    classes = [
        any(c.islower() for c in raw),
        any(c.isupper() for c in raw),
        any(c.isdigit() for c in raw),
        any((not c.isalnum()) for c in raw),
    ]
    return sum(1 for c in classes if c) >= MIN_PASSWORD_CLASSES


def resolve_inputs(domain: str, cert_dir: Path,
                   cert: Optional[Path], chain: Optional[Path],
                   key: Optional[Path]) -> tuple[Path, Optional[Path], Path]:
    """Resolve the leaf cert, optional chain, and private key paths."""
    cert_path = cert or (cert_dir / domain / "cert.pem")
    chain_path = chain or (cert_dir / domain / "chain.pem")
    key_path = key or (cert_dir / domain / "privkey.pem")
    return cert_path, chain_path, key_path


def prompt_password() -> str:
    """Interactively prompt for a password without echoing it."""
    pw = getpass.getpass("PFX export password (not echoed): ")
    if not password_meets_policy(pw):
        pw = getpass.getpass("PFX export password again (>=12 chars, 3 classes): ")
    return pw


def obtain_password(args: argparse.Namespace) -> str:
    """Resolve the PFX password from the explicit source requested."""
    if args.password_file:
        p = Path(args.password_file)
        if not p.exists():
            raise FileNotFoundError(f"--password-file not found: {p}")
        return p.read_text(encoding="utf-8").strip()
    if args.password:
        return args.password
    if args.password_env:
        val = os.environ.get(args.password_env, "")
        if val:
            return val
    return prompt_password()


@dataclass
class ExportResult:
    ok: bool
    out_path: str
    cert_subject: str
    chain_len: int
    error: str = ""
    detail: str = ""


def export_pfx(domain: str, cert_path: Path, key_path: Path,
               chain_path: Optional[Path], password: str, out_path: Path) -> ExportResult:
    """Serialise leaf + chain + key into an encrypted PKCS#12 blob."""
    if not _HAS_CRYPTO:
        return ExportResult(False, str(out_path), "", 0,
                            f"cryptography not available: {_CRYPTO_IMPORT_ERROR}")

    for required, name in ((cert_path, "certificate"), (key_path, "private key")):
        if not required.exists():
            return ExportResult(False, str(out_path), "", 0,
                                f"{name} not found: {required}")
    if chain_path is not None and not chain_path.exists():
        chain_path = None

    leaf_bytes = cert_path.read_bytes()
    key_bytes = key_path.read_bytes()
    chain_bytes = chain_path.read_bytes() if chain_path else None

    try:
        leaf_certs = load_pem_x509_certificates(leaf_bytes)
        cas = load_pem_x509_certificates(chain_bytes) if chain_bytes else None
        leaf = leaf_certs[0]
        key = load_pem_private_key(key_bytes, password=None)
    except Exception as e:
        return ExportResult(False, str(out_path), "", 0,
                            f"failed to parse certificate/key: {e}")

    try:
        blob = pkcs12.serialize_key_and_certificates(
            name=domain.encode("utf-8"),
            key=key,
            cert=leaf,
            cas=cas,
            encryption_algorithm=BestAvailableEncryption(password.encode("utf-8")),
        )
    except Exception as e:
        return ExportResult(False, str(out_path), "", 0,
                            f"PKCS12 serialisation failed: {e}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(blob)

    if sys.platform == "win32":
        try:
            import subprocess
            subprocess.run(
                ["icacls", str(out_path), "/inheritance:r",
                 "/grant:r", f"{os.environ.get('USERNAME','')}:R"],
                capture_output=True, timeout=10)
        except Exception:
            pass

    try:
        subject = leaf.subject.rfc4514_string()
    except Exception:
        subject = domain

    return ExportResult(True, str(out_path), subject,
                        len(leaf_certs) + (len(cas) if cas else 0),
                        detail=f"key+leaf{' + chain' if cas else ''} exported")


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="CertMate PFX export tool",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("domain")
    ap.add_argument("--cert", type=Path, default=None)
    ap.add_argument("--chain", type=Path, default=None)
    ap.add_argument("--key", type=Path, default=None)
    ap.add_argument("--cert-dir", default=DEFAULT_CERT_DIR)
    ap.add_argument("--out", default=None)
    ap.add_argument("--password", default=None)
    ap.add_argument("--password-file", default=None)
    ap.add_argument("--password-env", default=None)
    args = ap.parse_args(argv)

    if not args.password_env:
        args.password_env = "CERTMATE_PFX_PASSWORD"

    cert_dir = Path(args.cert_dir)
    cert_path, chain_path, key_path = resolve_inputs(
        args.domain, cert_dir, args.cert, args.chain, args.key)

    for required, name in ((cert_path, "certificate"), (key_path, "private key")):
        if not required.exists():
            print(f"[CertMate-pfx] FATAL: {name} not found: {required}", file=sys.stderr)
            print(f"[CertMate-pfx] Ensure the certificate for '{args.domain}' has been "
                  f"issued, or pass explicit --cert/--key paths.", file=sys.stderr)
            return 2

    password = obtain_password(args)
    if not password_meets_policy(password):
        print(f"[CertMate-pfx] FATAL: PFX password does not meet policy "
              f"(>= {MIN_PASSWORD_LEN} chars, {MIN_PASSWORD_CLASSES} of 4 classes).",
              file=sys.stderr)
        return 3

    out_path = Path(args.out) if args.out else Path(f"{args.domain}.pfx")

    result = export_pfx(args.domain, cert_path, key_path, chain_path,
                       password, out_path)
    if result.ok:
        print(f"[CertMate-pfx] OK  {result.out_path}")
        print(f"[CertMate-pfx]   subject : {result.cert_subject}")
        print(f"[CertMate-pfx]   contents: {result.detail}")
        print(f"[CertMate-pfx]   chain certs (incl leaf): {result.chain_len}")
        return 0

    print(f"[CertMate-pfx] FATAL: {result.error}", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
