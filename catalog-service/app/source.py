"""Read and fast-forward the devpod source clone a workspace builds from.

Blocking (subprocess git); callers hop through run_in_threadpool. Pull
authenticates with whatever git credentials the service account already
holds, the same ones devpod's own clone used.
"""

from __future__ import annotations

import json
import os
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
    # Never prompt: this runs in a daemon with no tty, where a credential
    # prompt is not an error message but a 60s hang ending in a confusing
    # "could not read Username".
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    return subprocess.run(["git", "-C", str(path), *args],
                          capture_output=True, text=True, timeout=60, env=env)


def _credential_args(helper: Path | None) -> list[str]:
    """`git -c` flags putting the helper in charge, or nothing."""
    if helper is None or not os.access(helper, os.X_OK):
        return []
    # The empty first entry clears helpers configured elsewhere, so the
    # service's auth does not depend on the host user's git config.
    return ["-c", "credential.helper=", "-c", f"credential.helper={helper}"]


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
    # Only tracked-file changes can block a fast-forward. Untracked files ride
    # along fine, and git itself refuses the merge if one would be overwritten,
    # so gating the pull on `dirty` sent people hunting for edits they never
    # made (a stray docs/ note was enough).
    r = _git(path, "status", "--porcelain", "--untracked-files=no")
    src.dirty_tracked = r.returncode == 0 and bool(r.stdout.strip())
    r = _git(path, "remote", "get-url", "origin")
    if r.returncode == 0:
        src.remote = r.stdout.strip() or None
    src.committed_pin = _pin_from_devcontainer(path)
    return src


def pull_source(ws_id: str, path: Path,
                credential_helper: Path | None = None) -> WorkspaceSource:
    src = read_source(ws_id, path)
    if not src.present:
        raise SourcePullError(404, f"no source clone at {path}")
    if src.detached:
        raise SourcePullError(
            409, "source clone is on a detached HEAD; check out a branch first")
    if src.dirty_tracked:
        raise SourcePullError(
            409, "source clone has uncommitted changes to tracked files; "
                 "refusing to pull over them")
    r = _git(path, *_credential_args(credential_helper), "pull", "--ff-only")
    if r.returncode != 0:
        err = r.stderr.strip()[:500]
        if "could not read Username" in err or "Authentication failed" in err:
            err += (" -- the service has no GitHub credentials for this "
                    "private repo; check that the credential helper at "
                    f"{credential_helper} is executable and that the secrets "
                    "store it reads holds GH_TOKEN")
        elif "Read-only file system" in err:
            err += (" -- the service's systemd sandbox does not grant write "
                    f"access to {path}; check ReadWritePaths= in "
                    "dvw-catalog.service")
        raise SourcePullError(502, f"git pull --ff-only failed: {err}")
    return read_source(ws_id, path)
