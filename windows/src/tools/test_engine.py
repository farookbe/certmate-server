from __future__ import annotations

import json
import os
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
TOOLS = HERE / "tools"
sys.path.insert(0, str(TOOLS))

import export_pfx  # noqa: E402
import updater  # noqa: E402

PASSED = 0
FAILED = 0
SKIP = 0


def report(ok: bool, name: str, detail: str = "") -> None:
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"  PASS  {name}")
    else:
        FAILED += 1
        print(f"  FAIL  {name} : {detail}")


def report_skip(name: str, reason: str = "") -> None:
    global SKIP
    SKIP += 1
    print(f"  SKIP  {name} : {reason}")


def test_pfx_password_policy() -> None:
    assert export_pfx.password_meets_policy("Ab1!Ab1!Ab1!")
    assert not export_pfx.password_meets_policy("short")
    assert not export_pfx.password_meets_policy("")
    assert not export_pfx.password_meets_policy("a" * 20)
    report(True, "pfx: password policy (accept/reject)")


def test_pfx_weak_password_refused() -> None:
    assert not export_pfx.password_meets_policy("weak")
    report(True, "pfx: weak password is refused by policy")


def test_pfx_missing_inputs() -> None:
    out = Path(tempfile.gettempdir()) / "nope.pfx"
    res = export_pfx.export_pfx(
        "missing", Path("C:\\nonexistent\\cert.pem"),
        Path("C:\\nonexistent\\key.pem"), None, "x" * 20, out)
    assert not res.ok and "not found" in res.error.lower()
    report(True, "pfx: missing cert/key is a clean FATAL, not a crash")


def _make_fake_zip(zip_path: Path, top_name: str) -> None:
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr(f"{top_name}/app.py", "print('upstream app')\n")
        zf.writestr(f"{top_name}/modules/__init__.py",
                    "__version__ = 'v99.0.0'\n")


def test_updater_check_only_no_install() -> None:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        pf = td / "Program Files" / "CertMate"
        pd = td / "ProgramData" / "CertMate"
        (pf / "app" / "modules").mkdir(parents=True)
        (pf / "app" / "modules" / "__init__.py").write_text(
            "__version__ = 'v1.0.0'\n", encoding="utf-8")
        pd.mkdir(parents=True)

        u = updater.Updater(program_files=str(pf), program_data=str(pd),
                            repo_root=HERE)
        latest = {"tag_name": "v2.0.0", "name": "v2.0.0",
                  "body": "routine maintenance", "draft": False,
                  "prerelease": False, "published_at": "2026-01-01"}
        target = {"tag_name": "v2.0.0", "name": "v2.0.0",
                  "body": "routine maintenance", "draft": False,
                  "prerelease": False, "published_at": "2026-01-01"}

        def fake_http(url: str) -> bytes:
            if url.endswith("/releases/latest"):
                return json.dumps(latest).encode()
            if "/releases/tags/" in url:
                return json.dumps(target).encode()
            raise AssertionError(f"unexpected url {url}")

        u._http_get = fake_http
        rep = u.check_update()
        assert rep["state"] == "ok", rep
        assert rep["is_upgrade"] is True, rep
        assert not (pf / ".rollback").exists()
        report(True, "updater: check-only reports upgrade, no side effects")


def test_updater_refuses_incompatible_downgrade() -> None:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        pf = td / "pf"
        pd = td / "pd"
        (pf / "app" / "modules").mkdir(parents=True)
        (pf / "app" / "modules" / "__init__.py").write_text(
            "__version__ = 'v9.0.0'\n", encoding="utf-8")
        pd.mkdir()

        fake_zip = td / "fake-release.zip"
        _make_fake_zip(fake_zip, "certmate-fake")

        u = updater.Updater(program_files=str(pf), program_data=str(pd),
                            repo_root=HERE)
        u._http_get = lambda url: fake_zip.read_bytes() \
            if "zipball" in url else json.dumps({
                "tag_name": "v1.0.0", "draft": False, "prerelease": False,
                "body": "this release performs a data migration",
                "published_at": ""}).encode()

        rep = u.run_update("v1.0.0", admin_approved=True)
        assert not rep.ok
        assert "not permitted" in rep.error.lower() or "downgrade" in rep.error.lower()
        report(True, "updater: incompatible downgrade is refused, no swap occurs")


def main() -> int:
    print("CertMate Windows engine test battery")
    print("  target: local temp fixtures (no live service, no network)")

    print("\n==> PFX export tool")
    test_pfx_password_policy()
    test_pfx_weak_password_refused()
    test_pfx_missing_inputs()

    print("\n==> Upstream update engine")
    test_updater_check_only_no_install()
    test_updater_refuses_incompatible_downgrade()

    print()
    print("=" * 60)
    print(f" Test results: {PASSED} passed, {FAILED} failed, {SKIP} skipped")
    print("=" * 60)
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
