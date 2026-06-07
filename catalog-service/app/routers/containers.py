from __future__ import annotations

from fastapi import APIRouter, Query

from ..deps import InspectorDep, StoreDep, run_inspect
from ..models import Orphan, WorkspaceStatus

router = APIRouter(prefix="/containers", tags=["containers"])


@router.get("/status", response_model=list[WorkspaceStatus])
async def status(
    store: StoreDep,
    inspector: InspectorDep,
    ids: list[str] | None = Query(default=None),
) -> list[WorkspaceStatus]:
    """Bulk liveness for workspaces (alive/stale/stopped/absent).

    Replaces dvw's _dvw_load_probe SSH fan-out with one local docker pass.
    Without `ids`, reports on every catalogued workspace.
    """
    if ids is None:
        ids = [w.id for w in store.list_workspaces()]
    return await run_inspect(inspector.status_many, ids)


@router.get("/orphans", response_model=list[Orphan])
async def orphans(store: StoreDep, inspector: InspectorDep) -> list[Orphan]:
    """Devpod-labelled containers whose workspace id is not in the catalog."""
    catalog_ids = store.workspace_ids()
    return await run_inspect(inspector.orphans, catalog_ids)
