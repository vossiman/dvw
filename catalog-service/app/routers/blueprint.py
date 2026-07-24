from __future__ import annotations

from collections.abc import Awaitable
from typing import TypeVar

from fastapi import APIRouter, Header, HTTPException, Response
from pydantic import BaseModel

from ..blueprint_store import BlueprintConflictError, FutureBlueprintVersionError
from ..deps import BlueprintStoreDep
from ..models import BlueprintUpdate

router = APIRouter(prefix="/blueprint", tags=["blueprint"])

T = TypeVar("T")


class Blueprint(BaseModel):
    content: str
    # Compatibility field: mtime epoch of the materialized effective file.
    version: int
    managed_version: int
    revision: str
    migration_status: str


class BlueprintCustom(BaseModel):
    content: str
    managed_version: int
    revision: str


async def _guarded(awaitable: Awaitable[T]) -> T:
    try:
        return await awaitable
    except (BlueprintConflictError, FutureBlueprintVersionError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


def _etag(response: Response, revision: str) -> None:
    response.headers["ETag"] = f'"{revision}"'


@router.get("", response_model=Blueprint)
async def get_blueprint(store: BlueprintStoreDep, response: Response) -> Blueprint:
    """Read the effective blueprint. Note this migrates/rematerializes on disk."""
    snapshot = await _guarded(store.aread())
    _etag(response, snapshot.revision)
    return Blueprint(
        content=snapshot.content,
        version=snapshot.version,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
        migration_status=snapshot.migration_status,
    )


@router.put("", response_model=Blueprint)
async def put_blueprint(
    body: BlueprintUpdate,
    store: BlueprintStoreDep,
    response: Response,
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Blueprint:
    """Compatibility whole-document PUT; managed markers remain read-only."""
    snapshot = await _guarded(
        store.awrite_effective_compat(body.content, expected_revision=if_match)
    )
    _etag(response, snapshot.revision)
    return Blueprint(
        content=snapshot.content,
        version=snapshot.version,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
        migration_status=snapshot.migration_status,
    )


@router.get("/custom", response_model=BlueprintCustom)
async def get_blueprint_custom(
    store: BlueprintStoreDep, response: Response
) -> BlueprintCustom:
    snapshot = await _guarded(store.aread())
    _etag(response, snapshot.revision)
    return BlueprintCustom(
        content=snapshot.custom_content,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
    )


@router.put("/custom", response_model=BlueprintCustom)
async def put_blueprint_custom(
    body: BlueprintUpdate,
    store: BlueprintStoreDep,
    response: Response,
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> BlueprintCustom:
    snapshot = await _guarded(
        store.awrite_custom(body.content, expected_revision=if_match)
    )
    _etag(response, snapshot.revision)
    return BlueprintCustom(
        content=snapshot.custom_content,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
    )
