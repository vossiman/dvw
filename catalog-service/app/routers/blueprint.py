from __future__ import annotations

import os
import tempfile

from fastapi import APIRouter
from pydantic import BaseModel

from ..deps import SettingsDep
from ..models import BlueprintUpdate

router = APIRouter(prefix="/blueprint", tags=["blueprint"])

_SEED = """\
# dvw blueprint — served by dvw-catalog (GET /v1/blueprint).
# Edit via `dvw -l`/the service; all machines pick it up on the next dvw call.
# Personal/host-specific config stays in ~/.ssh/config; only put shared
# config here.

Host *.devpod
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
"""


class Blueprint(BaseModel):
    content: str
    # mtime epoch (int) — the client refreshes its local copy when this is
    # newer than the local file's mtime, exactly like the old Dropbox model.
    version: int


def _read(settings: SettingsDep | None, path) -> Blueprint:
    if not path.exists():
        return Blueprint(content=_SEED, version=0)
    return Blueprint(content=path.read_text(), version=int(path.stat().st_mtime))


@router.get("", response_model=Blueprint)
async def get_blueprint(settings: SettingsDep) -> Blueprint:
    return _read(settings, settings.blueprint_path)


@router.put("", response_model=Blueprint)
async def put_blueprint(body: BlueprintUpdate, settings: SettingsDep) -> Blueprint:
    path = settings.blueprint_path
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        f.write(body.content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    return _read(settings, path)
