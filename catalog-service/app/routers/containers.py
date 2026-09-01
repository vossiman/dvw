from __future__ import annotations

from fastapi import APIRouter, Query
from starlette.concurrency import run_in_threadpool

from ..deps import BlueprintImageDep, InspectorDep, StoreDep, run_inspect
from ..models import Orphan, WaitingWindow, WorkspaceStatus, WorkspaceWindows

router = APIRouter(prefix="/containers", tags=["containers"])


@router.get("/status", response_model=list[WorkspaceStatus])
async def status(
    store: StoreDep,
    inspector: InspectorDep,
    blueprint: BlueprintImageDep,
    ids: list[str] | None = Query(default=None),
) -> list[WorkspaceStatus]:
    """Bulk liveness for workspaces (alive/stale/stopped/absent).

    Replaces dvw's _dvw_load_probe SSH fan-out with one local docker pass.
    Without `ids`, reports on every catalogued workspace.
    """
    if ids is None:
        ids = [w.id for w in store.list_workspaces()]
    bp = await run_in_threadpool(blueprint.get)
    return await run_inspect(inspector.status_many, ids, bp)


@router.get("/orphans", response_model=list[Orphan])
async def orphans(store: StoreDep, inspector: InspectorDep) -> list[Orphan]:
    """Devpod-labelled containers whose workspace id is not in the catalog."""
    catalog_ids = store.workspace_ids()
    return await run_inspect(inspector.orphans, catalog_ids)


@router.get("/waiting", response_model=list[WaitingWindow])
async def waiting(inspector: InspectorDep) -> list[WaitingWindow]:
    """tmux windows flagged @waiting by agent-notify, newest first."""
    return await run_inspect(inspector.waiting_windows)


@router.get("/windows", response_model=list[WorkspaceWindows])
async def windows(inspector: InspectorDep) -> list[WorkspaceWindows]:
    """Per-workspace tmux window snapshot (tree view). One exec per
    running container; failures degrade to an empty window list."""
    return await run_inspect(inspector.windows_many)
