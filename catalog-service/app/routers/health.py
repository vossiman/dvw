from __future__ import annotations

from fastapi import APIRouter

from .. import __version__
from ..deps import InspectorDep, StoreDep, run_inspect
from ..models import Health

router = APIRouter(tags=["health"])


@router.get("/health", response_model=Health)
async def health(store: StoreDep, inspector: InspectorDep) -> Health:
    docker_ok = await run_inspect(inspector.ping)
    return Health(
        version=__version__,
        docker=docker_ok,
        store_writable=store.store_writable(),
        workspaces=len(store.list_workspaces()),
    )
