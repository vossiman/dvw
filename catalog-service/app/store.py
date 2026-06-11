"""Atomic, single-writer JSON catalog store.

Durability model — the file is the single source of truth, with no sync layer
or replication behind it, so durability is made explicit here:
  * Every mutation goes through `_save`: temp file in the same dir, flush,
    fsync, then os.replace() — an atomic POSIX rename. No torn writes.
  * A single asyncio.Lock serializes every read-modify-write. This is correct
    *because* the service runs with `uvicorn --workers 1`; one process => one
    writer => concurrent-writer races on the catalog file are structurally
    impossible.

The in-memory `Catalog` is the working copy; the file is the durable log.
"""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
from pathlib import Path

from .models import (
    Catalog,
    Defaults,
    Repo,
    Workspace,
    utcnow_iso,
)


class NotFoundError(KeyError):
    pass


class ConflictError(Exception):
    pass


def _mru(items: list, key: str) -> list:
    """Sort by an ISO-8601 timestamp field, newest first. Stable."""
    return sorted(items, key=lambda x: getattr(x, key) or "", reverse=True)


class CatalogStore:
    def __init__(self, path: Path):
        self._path = path
        self._lock = asyncio.Lock()
        self._catalog = self._load()

    # ---- persistence ------------------------------------------------------

    def _load(self) -> Catalog:
        if not self._path.exists():
            return Catalog()
        raw = json.loads(self._path.read_text())
        return Catalog.model_validate(raw)

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = self._catalog.model_dump(mode="json", exclude_none=False)
        fd, tmp = tempfile.mkstemp(
            dir=self._path.parent, prefix=f".{self._path.name}.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, indent=2, sort_keys=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self._path)
        except BaseException:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise
        # fsync the directory so the rename itself is durable across a crash —
        # this file is the single source of truth, with no synced copy behind it.
        try:
            dfd = os.open(self._path.parent, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass

    def store_writable(self) -> bool:
        # Read-only probe (no mkdir side effect): used by the /health handler.
        try:
            return os.access(self._path.parent, os.W_OK)
        except OSError:
            return False

    # ---- whole-catalog ----------------------------------------------------

    def snapshot(self) -> Catalog:
        """Validated copy of the current catalog (safe to serialize)."""
        return self._catalog.model_copy(deep=True)

    # ---- workspaces -------------------------------------------------------

    def list_workspaces(self) -> list[Workspace]:
        return _mru(list(self._catalog.workspaces), "last_used_at")

    def get_workspace(self, ws_id: str) -> Workspace:
        for w in self._catalog.workspaces:
            if w.id == ws_id:
                return w
        raise NotFoundError(ws_id)

    async def add_workspace(self, w: Workspace) -> Workspace:
        async with self._lock:
            if any(x.id == w.id for x in self._catalog.workspaces):
                raise ConflictError(w.id)
            self._catalog.workspaces.append(w)
            self._save()
            return w

    async def patch_workspace(self, ws_id: str, fields: dict) -> Workspace:
        async with self._lock:
            w = self._require_workspace(ws_id)
            for k, v in fields.items():
                setattr(w, k, v)
            self._save()
            return w

    async def touch_workspace(self, ws_id: str) -> Workspace:
        async with self._lock:
            w = self._require_workspace(ws_id)
            w.last_used_at = utcnow_iso()
            self._save()
            return w

    async def remove_workspace(self, ws_id: str) -> None:
        async with self._lock:
            before = len(self._catalog.workspaces)
            self._catalog.workspaces = [
                x for x in self._catalog.workspaces if x.id != ws_id
            ]
            if len(self._catalog.workspaces) != before:
                self._save()

    def _require_workspace(self, ws_id: str) -> Workspace:
        for w in self._catalog.workspaces:
            if w.id == ws_id:
                return w
        raise NotFoundError(ws_id)

    def workspace_ids(self) -> set[str]:
        return {w.id for w in self._catalog.workspaces}

    # ---- repos ------------------------------------------------------------

    def list_repos(self) -> list[Repo]:
        return _mru(list(self._catalog.repos), "last_used_at")

    def get_repo(self, url: str) -> Repo:
        for r in self._catalog.repos:
            if r.url == url:
                return r
        raise NotFoundError(url)

    async def upsert_repo(self, url: str, last_branch: str | None) -> Repo:
        async with self._lock:
            now = utcnow_iso()
            for r in self._catalog.repos:
                if r.url == url:
                    if last_branch is not None:
                        r.last_branch = last_branch
                    r.last_used_at = now
                    self._save()
                    return r
            r = Repo(url=url, last_branch=last_branch, last_used_at=now)
            self._catalog.repos.append(r)
            self._save()
            return r

    # ---- defaults ---------------------------------------------------------

    def get_defaults(self) -> Defaults:
        return self._catalog.defaults

    async def update_defaults(self, fields: dict) -> Defaults:
        async with self._lock:
            for k, v in fields.items():
                setattr(self._catalog.defaults, k, v)
            self._save()
            return self._catalog.defaults
