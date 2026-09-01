from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Path, Response
from starlette.concurrency import run_in_threadpool

from .. import source as source_mod
from ..deps import (
    BlueprintImageDep,
    InspectorDep,
    SettingsDep,
    StoreDep,
    invalidate_resolve_cache,
    resolve_cached,
    run_inspect,
)
from ..models import (
    CanonicalContainer,
    ContainerInspect,
    SiblingContainer,
    Workspace,
    WorkspaceCreate,
    WorkspacePatch,
    WorkspaceSource,
    utcnow_iso,
)
from ..source import SourcePullError
from ..store import ConflictError, NotFoundError

router = APIRouter(prefix="/workspaces", tags=["workspaces"])

# Constrain the path param to the same charset as workspace ids. Defense in
# depth: downstream uses exact matches / fixed-argv, but rejecting junk early
# keeps the API honest (422 rather than a silent miss).
WsId = Annotated[str, Path(pattern=r"^[A-Za-z0-9._-]+$", max_length=128)]


@router.get("", response_model=list[Workspace])
async def list_workspaces(store: StoreDep) -> list[Workspace]:
    """All workspaces, MRU order (newest last_used_at first)."""
    return store.list_workspaces()


@router.get("/{ws_id}", response_model=Workspace)
async def get_workspace(ws_id: WsId, store: StoreDep) -> Workspace:
    try:
        return store.get_workspace(ws_id)
    except NotFoundError:
        raise HTTPException(404, f"workspace not found: {ws_id}")


@router.post("", response_model=Workspace, status_code=201)
async def create_workspace(body: WorkspaceCreate, store: StoreDep) -> Workspace:
    defaults = store.get_defaults()
    now = utcnow_iso()
    w = Workspace(
        id=body.id,
        repo=body.repo,
        branch=body.branch,
        ide=body.ide or "ssh",
        provider=body.provider or defaults.provider,
        created_on=body.created_on,
        created_at=now,
        last_used_at=now,
    )
    try:
        return await store.add_workspace(w)
    except ConflictError:
        raise HTTPException(409, f"workspace already exists: {body.id}")


@router.patch("/{ws_id}", response_model=Workspace)
async def patch_workspace(
    ws_id: WsId, body: WorkspacePatch, store: StoreDep
) -> Workspace:
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        return await _get_or_404(store, ws_id)
    try:
        ws = await store.patch_workspace(ws_id, fields)
    except NotFoundError:
        raise HTTPException(404, f"workspace not found: {ws_id}")
    invalidate_resolve_cache(ws_id)
    return ws


@router.post("/{ws_id}/touch", response_model=Workspace)
async def touch_workspace(ws_id: WsId, store: StoreDep) -> Workspace:
    try:
        return await store.touch_workspace(ws_id)
    except NotFoundError:
        raise HTTPException(404, f"workspace not found: {ws_id}")


@router.delete("/{ws_id}", status_code=204)
async def delete_workspace(ws_id: WsId, store: StoreDep) -> Response:
    await store.remove_workspace(ws_id)
    invalidate_resolve_cache(ws_id)
    return Response(status_code=204)


@router.get("/{ws_id}/source", response_model=WorkspaceSource)
async def workspace_source(
    ws_id: WsId, store: StoreDep, settings: SettingsDep
) -> WorkspaceSource:
    await _get_or_404(store, ws_id)
    return await run_in_threadpool(
        source_mod.read_source, ws_id, settings.source_path(ws_id))


@router.post("/{ws_id}/source/pull", response_model=WorkspaceSource)
async def workspace_source_pull(
    ws_id: WsId, store: StoreDep, settings: SettingsDep
) -> WorkspaceSource:
    await _get_or_404(store, ws_id)
    try:
        return await run_in_threadpool(
            source_mod.pull_source, ws_id, settings.source_path(ws_id))
    except SourcePullError as exc:
        raise HTTPException(status_code=exc.status, detail=exc.detail)


# ---- the new, authoritative resolver + deep inspect -----------------------


@router.get("/{ws_id}/container", response_model=CanonicalContainer)
async def resolve_container(
    ws_id: WsId, inspector: InspectorDep, settings: SettingsDep
) -> CanonicalContainer:
    """Resolve workspace id -> its canonical docker container, locally.

    Replaces dvw's client-side SSH + bind-mount grep + tmux tie-break.
    container_id is null when no live container currently mounts the
    workspace (a valid state, returned 200, not 404).
    """
    return await resolve_cached(inspector, settings, ws_id)


@router.get("/{ws_id}/siblings", response_model=list[SiblingContainer])
async def workspace_siblings(
    ws_id: WsId, inspector: InspectorDep
) -> list[SiblingContainer]:
    """Per-container detail for every RUNNING container of this workspace.

    Normally a one-element list. More than one means duplicate siblings, which
    connect refuses to disambiguate unless exactly one has a live tmux `work`
    session. Returns the fields needed to decide WHICH to remove — tmux
    activity and /workspaces ownership — so the operator is not guessing.

    Execs into each container, so it is intentionally a per-workspace call:
    ask only for ids that /v1/containers/status flagged running_siblings > 1.
    """
    return await run_inspect(inspector.siblings, ws_id)


@router.get("/{ws_id}/inspect", response_model=ContainerInspect)
async def inspect_container(
    ws_id: WsId, inspector: InspectorDep, blueprint: BlueprintImageDep
) -> ContainerInspect:
    """Deep inspection: state, health, mounts, cpu/mem, disk, liveness."""
    bp = await run_in_threadpool(blueprint.get)
    return await run_inspect(inspector.inspect, ws_id, bp)


async def _get_or_404(store: StoreDep, ws_id: str) -> Workspace:
    try:
        return store.get_workspace(ws_id)
    except NotFoundError:
        raise HTTPException(404, f"workspace not found: {ws_id}")
