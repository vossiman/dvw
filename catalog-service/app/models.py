"""Pydantic v2 models.

The on-disk catalog deliberately mirrors the legacy Dropbox `catalog.json`
schema (version / defaults / workspaces[] / repos[], ISO-8601 UTC timestamps)
so that:
  * migration from the old file is a straight copy + validate, and
  * the file stays hand-editable (a property the original design prized).

`devpod_state` is an OPAQUE snapshot of devpod's own workspace.json. We never
model its internals — devpod's schema is theirs to change.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Workspace ids and repo branches end up in shell commands, file paths, and the
# /workspaces/<id> bind-mount destination, so keep the charset tight.
_ID_PATTERN = r"^[A-Za-z0-9._-]+$"

CATALOG_VERSION = 1


def utcnow_iso() -> str:
    """ISO-8601 UTC, second precision, trailing Z — matches catalog_now()."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _default_provider() -> str:
    """devpod provider name stamped on entries that don't carry one.

    Env-driven (CATALOG_DEFAULT_PROVIDER) so the catalog isn't hardwired to one
    site's provider; read at instantiation, not import, so it tracks the env the
    service runs under. Real catalog data overrides it per entry.
    """
    return os.getenv("CATALOG_DEFAULT_PROVIDER", "vossisrv")


class Defaults(BaseModel):
    model_config = ConfigDict(extra="allow")
    ide: str = "cursor"
    provider: str = Field(default_factory=_default_provider)


class Repo(BaseModel):
    model_config = ConfigDict(extra="allow")
    url: str
    last_branch: str | None = None
    last_used_at: str = Field(default_factory=utcnow_iso)


class Workspace(BaseModel):
    # validate_assignment so store.patch_workspace's setattr re-validates fields
    # (e.g. a bad branch type) instead of silently accepting them.
    model_config = ConfigDict(extra="allow", validate_assignment=True)

    id: str = Field(pattern=_ID_PATTERN, min_length=1, max_length=128)
    repo: str
    branch: str
    ide: str = "cursor"
    provider: str = Field(default_factory=_default_provider)
    # Defaults are None (not auto-stamped) so loading a hand-edited/partial
    # legacy entry round-trips faithfully without jumping to the top of MRU.
    # New workspaces get stamped on the create path (routers/workspaces.py).
    created_at: str | None = None
    last_used_at: str | None = None
    created_on: str | None = None
    # devpod's uid for this workspace's container (label dev.containers.id).
    uid: str | None = None
    # Verbatim snapshot of devpod's client-side workspace.json. Opaque.
    devpod_state: dict[str, Any] | None = None

    @property
    def workspace_path(self) -> str:
        return f"/workspaces/{self.id}"


class Catalog(BaseModel):
    """The whole store. Serializes back to the legacy on-disk shape."""

    model_config = ConfigDict(extra="allow")
    version: int = CATALOG_VERSION
    defaults: Defaults = Field(default_factory=Defaults)
    workspaces: list[Workspace] = Field(default_factory=list)
    repos: list[Repo] = Field(default_factory=list)

    @field_validator("version")
    @classmethod
    def _reject_future_version(cls, v: int) -> int:
        # Forward-compat guard: refuse to load/import a catalog written by a
        # newer dvw-catalog rather than silently mishandle an unknown schema.
        # (Restores the safety the legacy client had; older/seed versions —
        # incl. the version-0 empty seed — are still accepted.)
        if v > CATALOG_VERSION:
            raise ValueError(
                f"catalog schema version {v} is newer than this service "
                f"supports ({CATALOG_VERSION}); upgrade dvw-catalog"
            )
        return v


# ---- Request bodies -------------------------------------------------------


class WorkspaceCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=_ID_PATTERN, min_length=1, max_length=128)
    repo: str
    branch: str
    ide: str | None = None
    provider: str | None = None
    created_on: str | None = None


class WorkspacePatch(BaseModel):
    """All optional — only provided fields are updated."""

    model_config = ConfigDict(extra="forbid")
    repo: str | None = None
    branch: str | None = None
    ide: str | None = None
    provider: str | None = None
    uid: str | None = None
    devpod_state: dict[str, Any] | None = None


class RepoUpsert(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: str
    last_branch: str | None = None


class DefaultsUpdate(BaseModel):
    model_config = ConfigDict(extra="allow")
    ide: str | None = None
    provider: str | None = None


class BlueprintUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    content: str


# ---- Docker / resolver results -------------------------------------------


class CanonicalContainer(BaseModel):
    """Result of resolving a workspace id -> its docker container.

    container_id is None when no live container currently mounts
    /workspaces/<id> (a valid state, not an error).
    """

    workspace_id: str
    container_id: str | None = None
    container_name: str | None = None
    devpod_uid: str | None = None
    state: str | None = None  # running / exited / created / ...
    tmux_work_activity: int = -1
    sibling_ids: list[str] = Field(default_factory=list)
    resolved_by: str = "mount+tmux-tiebreak"
    # True when there are >=2 candidate containers and none has a live tmux
    # `work` session — the legacy resolver REFUSES to guess here (returns
    # status 1) rather than route the user into an arbitrary sibling. The
    # client must treat this as "do not proceed", same as the old behavior.
    ambiguous: bool = False


class BindMount(BaseModel):
    source: str
    destination: str
    rw: bool = True


class ContainerInspect(BaseModel):
    """Deep inspection of a single workspace's canonical container."""

    workspace_id: str
    container_id: str | None = None
    container_name: str | None = None
    devpod_uid: str | None = None
    devpod_user: str | None = None
    status: str | None = None
    running: bool = False
    exit_code: int | None = None
    health: str | None = None
    created: str | None = None
    started_at: str | None = None
    image: str | None = None
    restart_count: int = 0
    workspace_source: str | None = None
    bind_mounts: list[BindMount] = Field(default_factory=list)
    cpu_pct: float | None = None
    mem_bytes: int | None = None
    mem_limit: int | None = None
    mem_pct: float | None = None
    disk_bytes: int | None = None
    # alive / stale / stopped / absent — see resolver semantics.
    liveness: str = "absent"


class WorkspaceStatus(BaseModel):
    """Bulk per-workspace state, replacing dvw's _dvw_load_probe.

    liveness:
      alive    container running, /proc/1/cwd is a live inode
      stale    container running but its bind-mount source is gone (deleted)
      stopped  container exists but is not running
      absent   no container mounts /workspaces/<id>
    """

    id: str
    liveness: str
    container_id: str | None = None
    devpod_uid: str | None = None


class Orphan(BaseModel):
    """A devpod-labelled container whose workspace id is not in the catalog."""

    container_id: str
    container_name: str | None = None
    devpod_uid: str | None = None
    workspace_id: str | None = None
    state: str | None = None
    mount_status: str = "alive"  # alive / deleted / nomount
    mount_source: str | None = None


class Health(BaseModel):
    status: str = "ok"
    version: str
    docker: bool
    store_writable: bool
    workspaces: int
