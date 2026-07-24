from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, Response
from pydantic import BaseModel

from ..blueprint_store import (
    BlueprintConflictError,
    BlueprintSnapshot,
    BlueprintStore,
    FutureBlueprintVersionError,
)
from ..deps import SettingsDep
from ..models import BlueprintUpdate

router = APIRouter(prefix="/blueprint", tags=["blueprint"])


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


def _store(settings: SettingsDep) -> BlueprintStore:
    return BlueprintStore(
        effective_path=settings.blueprint_path,
        custom_path=settings.blueprint_custom_path,
        meta_path=settings.blueprint_meta_path,
        legacy_backup_path=settings.blueprint_legacy_backup_path,
    )


def _read(store: BlueprintStore) -> BlueprintSnapshot:
    try:
        return store.read()
    except (BlueprintConflictError, FutureBlueprintVersionError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


def _etag(response: Response, revision: str) -> None:
    response.headers["ETag"] = f'"{revision}"'


@router.get("", response_model=Blueprint)
async def get_blueprint(settings: SettingsDep, response: Response) -> Blueprint:
    snapshot = _read(_store(settings))
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
    settings: SettingsDep,
    response: Response,
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Blueprint:
    """Compatibility whole-document PUT; managed markers remain read-only."""
    try:
        snapshot = _store(settings).write_effective_compat(
            body.content, expected_revision=if_match
        )
    except (BlueprintConflictError, FutureBlueprintVersionError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
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
    settings: SettingsDep, response: Response
) -> BlueprintCustom:
    snapshot = _read(_store(settings))
    _etag(response, snapshot.revision)
    return BlueprintCustom(
        content=snapshot.custom_content,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
    )


@router.put("/custom", response_model=BlueprintCustom)
async def put_blueprint_custom(
    body: BlueprintUpdate,
    settings: SettingsDep,
    response: Response,
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> BlueprintCustom:
    try:
        snapshot = _store(settings).write_custom(
            body.content, expected_revision=if_match
        )
    except (BlueprintConflictError, FutureBlueprintVersionError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    _etag(response, snapshot.revision)
    return BlueprintCustom(
        content=snapshot.custom_content,
        managed_version=snapshot.managed_version,
        revision=snapshot.revision,
    )
