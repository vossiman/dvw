from __future__ import annotations

from fastapi import APIRouter

from ..deps import StoreDep
from ..models import Defaults, DefaultsUpdate

router = APIRouter(prefix="/defaults", tags=["defaults"])


@router.get("", response_model=Defaults)
async def get_defaults(store: StoreDep) -> Defaults:
    return store.get_defaults()


@router.put("", response_model=Defaults)
async def update_defaults(body: DefaultsUpdate, store: StoreDep) -> Defaults:
    fields = body.model_dump(exclude_unset=True)
    return await store.update_defaults(fields)
