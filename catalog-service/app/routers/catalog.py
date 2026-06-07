from __future__ import annotations

from fastapi import APIRouter

from ..deps import StoreDep
from ..models import Catalog

router = APIRouter(tags=["catalog"])


@router.get("/catalog", response_model=Catalog)
async def get_catalog(store: StoreDep) -> Catalog:
    """The whole catalog in the legacy on-disk schema.

    Lets `dvw doctor` and ad-hoc `jq` queries keep working unchanged.
    """
    return store.snapshot()
