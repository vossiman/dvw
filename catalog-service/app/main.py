"""FastAPI application: lifespan wiring, uniform error envelope, routers.

Run (dev):   uvicorn app.main:app --reload
Run (prod):  uvicorn app.main:app --uds /run/dvw-catalog/catalog.sock --workers 1
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import __version__
from .config import get_settings
from .deps import require_auth
from .docker_inspect import DockerInspector
from .routers import (
    blueprint,
    catalog,
    containers,
    defaults,
    health,
    repos,
    workspaces,
)
from .store import CatalogStore

log = logging.getLogger("dvw-catalog")


@asynccontextmanager
async def lifespan(app: FastAPI):
    import fcntl

    settings = get_settings()
    app.state.settings = settings

    # The atomic-write safety relies on a single writer process. Enforce it
    # (don't just document it): an exclusive, non-blocking flock means a second
    # uvicorn worker fails fast instead of silently racing the catalog file.
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    wlock = open(settings.data_dir / ".writer.lock", "w")
    try:
        fcntl.flock(wlock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        raise RuntimeError(
            "another dvw-catalog writer holds the lock — run with --workers 1"
        ) from e
    app.state._writer_lock = wlock  # keep the fd alive for the process lifetime

    app.state.store = CatalogStore(settings.catalog_path)
    # Docker client is created here, not at import time, so the module imports
    # (and tests) don't require a running daemon.
    app.state.inspector = DockerInspector(settings)
    log.info(
        "dvw-catalog %s started: catalog=%s docker_host=%s",
        __version__,
        settings.catalog_path,
        settings.docker_host or "<local socket>",
    )
    yield


def _error(status: int, code: str, message: str, details=None) -> JSONResponse:
    body = {"error": {"code": code, "message": message}}
    if details is not None:
        body["error"]["details"] = details
    return JSONResponse(status_code=status, content=body)


def create_app() -> FastAPI:
    app = FastAPI(
        title="dvw-catalog",
        version=__version__,
        summary="DevPod workspace catalog + authoritative container resolver",
        lifespan=lifespan,
    )

    @app.exception_handler(HTTPException)
    async def _http_exc(request: Request, exc: HTTPException):
        code = {
            400: "bad_request",
            401: "unauthorized",
            404: "not_found",
            409: "conflict",
        }.get(exc.status_code, "error")
        return _error(exc.status_code, code, str(exc.detail))

    @app.exception_handler(RequestValidationError)
    async def _validation_exc(request: Request, exc: RequestValidationError):
        return _error(422, "validation_error", "request validation failed", exc.errors())

    # /v1, all guarded by the (no-op-unless-configured) auth dependency.
    v1 = [
        health.router,
        catalog.router,
        workspaces.router,
        repos.router,
        defaults.router,
        blueprint.router,
        containers.router,
    ]
    for r in v1:
        app.include_router(r, prefix="/v1", dependencies=[Depends(require_auth)])

    return app


app = create_app()
