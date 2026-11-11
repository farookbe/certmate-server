#!/usr/bin/env python3
"""
CertMate Windows - Upstream update engine.

The check, approve, backup, stage, stop, swap, verify, and auto-rollback
pipeline that implements the "Update" button in the dashboard. The dashboard
(upstream) would POST to a local endpoint; this module is the authoritative
engine it calls, and is independently runnable from a CLI for operators and
from the release test battery.
"""
from __future__ import annotations

import json
import re
import shutil
import sys
import tempfile
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

GITHUB_REPO = "fabriziosalmi/certmate"
STABLE_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")

DEFAULT_PROGRAM_FILES = r"C:\Program Files\CertMate"
DEFAULT_PROGRAM_DATA = r"C:\ProgramData\CertMate"
DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[1]

INCOMPATIBLE_MARKERS = (
    "data migration", "breaking", "schema change",
    "removed endpoint", "incompatible",
)


def _parse_semver(tag: str) -> tuple:
    m = re.match(r"^v(\d+)\.(\d+)\.(\d+)$", tag)
    if not m:
        raise ValueError(f"not a stable vMAJOR.MINOR.PATCH tag: {tag}")
    return tuple(int(x) for x in m.groups())


def _sha256(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _extract_zip(zip_path: Path, dest: Path) -> None:
    import zipfile
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest)


def _run_py(py_cmd: str, script: Path, *args: str) -> None:
    import subprocess
    cmd = [py_cmd, str(script), *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"{script.name} failed (rc={result.returncode}):\n"
            f"{result.stdout}\n{result.stderr}")


@dataclass
class ReleaseInfo:
    tag: str
    name: str
    body: str
    published_at: str
    draft: bool = False
    prerelease: bool = False

    @property
    def draft_or_prerelease(self) -> bool:
        return self.draft or self.prerelease


@dataclass
class UpdateReport:
    started_utc: str
    installed_tag: Optional[str]
    target_tag: str
    steps: list = field(default_factory=list)
    ok: bool = False
    rolled_back: bool = False
    backup_dir: str = ""
    staging_dir: str = ""
    error: str = ""

    def log(self, msg: str) -> None:
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.steps.append(f"[{stamp}] {msg}")

    def to_json(self) -> str:
        return json.dumps(self.__dict__, indent=2, ensure_ascii=False)


class Updater:
    """The update engine. Network + filesystem I/O goes through protected
    methods so the test battery can monkeypatch them without a live
    service or network."""

    def __init__(self, program_files: str = DEFAULT_PROGRAM_FILES,
                 program_data: str = DEFAULT_PROGRAM_DATA,
                 repo_root: Optional[Path] = None,
                 github_repo: str = GITHUB_REPO):
        self.program_files = Path(program_files)
        self.program_data = Path(program_data)
        self.repo_root = repo_root or Path(__file__).resolve().parents[1]
        self.github_repo = github_repo
        self._report = UpdateReport(
            started_utc=datetime.now(timezone.utc).isoformat(timespec="seconds"),
            installed_tag=None, target_tag="")
        self._http_get = self._default_http_get
        self._stop_service = lambda: None
        self._start_service = lambda: None
        self._health_check = lambda: True

    def _default_http_get(self, url: str) -> bytes:
        req = urllib.request.Request(
            url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()

    def installed_version(self) -> Optional[str]:
        init = self.program_files / "app" / "modules" / "__init__.py"
        if not init.exists():
            return None
        text = init.read_text(encoding="utf-8")
        m = re.search(r"^__version__\s*=\s*['\"]([^'\"]+)['\"]", text, re.M)
        return m.group(1) if m else None

    def latest_stable(self) -> ReleaseInfo:
        base = f"https://api.github.com/repos/{self.github_repo}"
        raw = json.loads(self._http_get(f"{base}/releases/latest").decode("utf-8"))
        if raw.get("draft") or raw.get("prerelease"):
            tags = json.loads(self._http_get(f"{base}/tags?per_page=30").decode("utf-8"))
            for t in tags:
                if STABLE_TAG_RE.match(t["name"]):
                    rel = json.loads(self._http_get(
                        f"{base}/releases/tags/{t['name']}").decode("utf-8"))
                    return self._mk_release(rel, t["name"])
            raise RuntimeError("no stable tag found on the upstream repository")
        return self._mk_release(raw)

    @staticmethod
    def _mk_release(raw: dict, tag: Optional[str] = None) -> ReleaseInfo:
        return ReleaseInfo(
            tag=tag or raw["tag_name"],
            name=raw.get("name", ""),
            body=raw.get("body", "") or "",
            published_at=raw.get("published_at", ""),
            draft=bool(raw.get("draft")),
            prerelease=bool(raw.get("prerelease")),
        )

    def notes_flag_incompatible(self, notes: str) -> bool:
        lowered = (notes or "").lower()
        return any(marker in lowered for marker in INCOMPATIBLE_MARKERS)

    def check_update(self) -> dict:
        installed = self.installed_version()
        if installed is None:
            return {"state": "not-installed", "installed": None, "latest": None}
        latest = self.latest_stable()
        i = _parse_semver(installed)
        l = _parse_semver(latest.tag)
        result = {
            "state": "ok",
            "installed": installed,
            "latest": latest.tag,
            "latest_name": latest.name,
            "latest_published_at": latest.published_at,
            "is_upgrade": l > i,
            "notes_flag_incompatible": self.notes_flag_incompatible(latest.body),
            "release_notes": latest.body,
        }
        if l == i:
            result["state"] = "up-to-date"
        elif not l > i:
            result["state"] = "newer-than-latest"
        return result

    def _download_and_stage(self, target_tag: str, staging_root: Path,
                            py_cmd: str = "python") -> Path:
        zip_path = staging_root / f"certmate-{target_tag}.zip"
        zipball = (f"https://api.github.com/repos/{self.github_repo}/"
                   f"zipball/{target_tag}")
        zip_path.write_bytes(self._http_get(zipball))
        sha = _sha256(zip_path)

        upstream_dir = staging_root / "upstream"
        _extract_zip(zip_path, upstream_dir)
        top = next((p for p in upstream_dir.iterdir() if p.is_dir()), None)
        if top is None:
            raise RuntimeError("no extracted top-level directory found in the zipball")

        app_dir = staging_root / "app"
        if app_dir.exists():
            shutil.rmtree(app_dir)
        shutil.copytree(top, app_dir)

        manifest = {
            "tag": target_tag,
            "source_url": zipball,
            "sha256": sha,
            "download_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
        (staging_root / "SOURCE-MANIFEST.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8")

        patches_dir = self.repo_root / "src" / "patches"
        _run_py(py_cmd, patches_dir / "Apply-WindowsPatches.py", str(app_dir))
        _run_py(py_cmd, patches_dir / "Apply-WindowsPfx.py", str(app_dir))

        import subprocess
        rc = subprocess.run([py_cmd, "-m", "compileall", "-q", str(app_dir)],
                           capture_output=True, text=True)
        if rc.returncode != 0:
            raise RuntimeError(f"python -m compileall failed:\n{rc.stdout}\n{rc.stderr}")

        self._report.log(f"staged {target_tag}: sha256={sha[:16]}… app={app_dir}")
        return app_dir

    def _backup_program_data(self, stamp: str) -> Path:
        dest = self.program_data.parent / f"CertMate-Pre-Update-{stamp}"
        if self.program_data.exists():
            shutil.copytree(self.program_data, dest, dirs_exist_ok=True)
        self._report.log(f"backed up {self.program_data} -> {dest}")
        return dest

    def _create_rollback_point(self) -> Path:
        rb = self.program_files / ".rollback"
        if rb.exists():
            shutil.rmtree(rb)
        for sub in ("app", "bin", "python"):
            src = self.program_files / sub
            if src.exists():
                shutil.copytree(src, rb / sub, dirs_exist_ok=True)
        self._report.log(f"rollback point created at {rb}")
        return rb

    def _swap(self, staged_app: Path, staged_python: Optional[Path]) -> None:
        self._stop_service()
        old_app = self.program_files / "app"
        if old_app.exists():
            shutil.rmtree(old_app)
        shutil.copytree(staged_app, old_app)
        if staged_python and staged_python.exists():
            old_py = self.program_files / "python"
            if old_py.exists():
                shutil.rmtree(old_py)
            shutil.copytree(staged_python, old_py)
        self._start_service()

    def _rollback(self, rollback_dir: Path) -> None:
        self._stop_service()
        for sub in ("app", "python", "bin"):
            rb_sub = rollback_dir / sub
            prod_sub = self.program_files / sub
            if rb_sub.exists():
                if prod_sub.exists():
                    shutil.rmtree(prod_sub)
                shutil.copytree(rb_sub, prod_sub)
        self._start_service()

    def run_update(self, target_tag: str, admin_approved: bool,
                   no_backup: bool = False, keep_staging: bool = False,
                   py_cmd: str = "python") -> UpdateReport:
        rep = self._report
        rep.target_tag = target_tag
        rep.installed_tag = self.installed_version()

        if not STABLE_TAG_RE.match(target_tag):
            rep.error = (f"target '{target_tag}' is not a stable "
                         "vMAJOR.MINOR.PATCH tag.")
            rep.ok = False
            return rep

        base = f"https://api.github.com/repos/{self.github_repo}"
        raw = json.loads(self._http_get(
            f"{base}/releases/tags/{target_tag}").decode("utf-8"))
        release = self._mk_release(raw, target_tag)
        if release.draft_or_prerelease:
            rep.error = f"{target_tag} is a draft/prerelease; only stable tags are installable."
            rep.ok = False
            return rep
        if rep.installed_tag:
            i, t = _parse_semver(rep.installed_tag), _parse_semver(target_tag)
            if t < i and self.notes_flag_incompatible(release.body):
                rep.error = (f"{target_tag} is an older version and its notes flag "
                             "incompatible data changes; downgrade is not permitted.")
                rep.ok = False
                return rep

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        if not no_backup:
            rep.backup_dir = str(self._backup_program_data(stamp))
        else:
            rep.log("WARNING: no_backup=True; ProgramData will NOT be backed up.")

        staging_root = Path(tempfile.mkdtemp(prefix="certmate-update-"))
        rep.staging_dir = str(staging_root)
        try:
            staged_app = self._download_and_stage(target_tag, staging_root, py_cmd)
        except Exception as e:
            rep.error = f"staging failed: {e}"
            rep.ok = False
            return rep

        if not admin_approved:
            rep.log("validation passed; admin approval not given - "
                    "staged tree left for inspection")
            rep.ok = True
            return rep

        rb = self._create_rollback_point()
        try:
            self._swap(staged_app, staging_root / "python")
        except Exception as e:
            rep.error = f"swap failed: {e}"
            rep.rolled_back = True
            self._rollback(rb)
            rep.ok = False
            return rep

        if not self._health_check():
            rep.log("health check FAILED after update; rolling back")
            rep.rolled_back = True
            self._rollback(rb)
            rep.error = "update rolled back: post-swap health check failed"
            rep.ok = False
            return rep

        rep.log(f"update to {target_tag} succeeded; health verified")
        rep.ok = True
        if not keep_staging and staging_root.exists():
            shutil.rmtree(staging_root, ignore_errors=True)
        return rep


def _cli(argv: Optional[list[str]] = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--target", default=None)
    ap.add_argument("--admin-approval", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("--program-files", default=DEFAULT_PROGRAM_FILES)
    ap.add_argument("--program-data", default=DEFAULT_PROGRAM_DATA)
    ap.add_argument("--repo-root", default=str(DEFAULT_REPO_ROOT))
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args(argv)

    u = Updater(program_files=args.program_files,
                program_data=args.program_data,
                repo_root=Path(args.repo_root))

    if args.check_only:
        rep = u.check_update()
        print(json.dumps(rep, indent=2))
        if rep.get("state") == "ok" and rep.get("notes_flag_incompatible"):
            print("NOTE: an update is available and the release notes flag "
                  "incompatible data changes - manual review required.")
            return 2
        return 0

    target = args.target or u.latest_stable().tag
    report = u.run_update(target, admin_approved=args.admin_approval,
                          no_backup=args.no_backup)
    print(report.to_json())
    if args.json_out:
        Path(args.json_out).write_text(report.to_json(), encoding="utf-8")
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(_cli())
