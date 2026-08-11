"""Default workspace-name derivation for the wizard. Mirrors lib/wizard.sh's
_sanitize_ws_name/_repo_leaf/_truncate_for_devpod — tiny pure functions,
duplicated by design; the bash side revalidates authoritatively."""

from __future__ import annotations

import re

DEVPOD_NAME_MAX = 48


def _repo_leaf(url: str) -> str:
    leaf = re.split(r"[/:]", url.rstrip("/"))[-1]
    return leaf[:-4] if leaf.endswith(".git") else leaf


def _sanitize(raw: str) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9-]+", "-", raw.lower()))


def default_workspace_name(repo: str, branch: str) -> str:
    name = _sanitize(f"{_repo_leaf(repo)}-{branch}")[:DEVPOD_NAME_MAX]
    return name.rstrip("-")
