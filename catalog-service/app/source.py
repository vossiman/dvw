"""Read and fast-forward the devpod source clone a workspace builds from.

Blocking (subprocess git); callers hop through run_in_threadpool. Pull
authenticates with whatever git credentials the service account already
holds, the same ones devpod's own clone used.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from .models import WorkspaceSource

_IMAGE_RE = re.compile(r'"image"\s*:\s*"([^"]+)"')


class SourcePullError(Exception):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _git(path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(path), *args],
                          capture_output=True, text=True, timeout=60)


def _pin_from_devcontainer(path: Path) -> str | None:
    f = path / ".devcontainer" / "devcontainer.json"
    if not f.is_file():
        return None
    try:
        text = f.read_text()
    except OSError:
        return None
    try:
        image = json.loads(text).get("image")
        if isinstance(image, str):
            return image
    except ValueError:
        pass  # JSONC; fall through to the regex
    m = _IMAGE_RE.search(text)
    return m.group(1) if m else None


def read_source(ws_id: str, path: Path) -> WorkspaceSource:
    src = WorkspaceSource(workspace_id=ws_id, path=str(path))
    if not (path / ".git").exists():
        return src
    src.present = True
    r = _git(path, "rev-parse", "HEAD")
    if r.returncode == 0:
        src.head = r.stdout.strip() or None
    r = _git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
    if r.returncode == 0 and r.stdout.strip():
        src.branch = r.stdout.strip()
    else:
        src.detached = True
    r = _git(path, "status", "--porcelain")
    src.dirty = r.returncode == 0 and bool(r.stdout.strip())
    r = _git(path, "remote", "get-url", "origin")
    if r.returncode == 0:
        src.remote = r.stdout.strip() or None
    src.committed_pin = _pin_from_devcontainer(path)
    return src


def pull_source(ws_id: str, path: Path) -> WorkspaceSource:
    src = read_source(ws_id, path)
    if not src.present:
        raise SourcePullError(404, f"no source clone at {path}")
    if src.detached:
        raise SourcePullError(
            409, "source clone is on a detached HEAD; check out a branch first")
    if src.dirty:
        raise SourcePullError(
            409, "source clone has uncommitted changes; refusing to pull over them")
    r = _git(path, "pull", "--ff-only")
    if r.returncode != 0:
        raise SourcePullError(
            502, f"git pull --ff-only failed: {r.stderr.strip()[:500]}")
    return read_source(ws_id, path)
