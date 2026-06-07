"""Dependency providers and the async <-> blocking-docker bridge.

Routers depend on `get_store` / `get_inspector` (overridable in tests) and call
docker through `run_inspect`, which hops to a threadpool so the blocking SDK
never stalls the event loop. `resolve_cached` adds a short TTL cache over the
hot resolver path.
"""

from __future__ import annotations

import secrets
import time
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request
from starlette.concurrency import run_in_threadpool

from .config import Settings, get_settings
from .docker_inspect import Inspector
from .models import CanonicalContainer
from .store import CatalogStore

SettingsDep = Annotated[Settings, Depends(get_settings)]


def get_store(request: Request) -> CatalogStore:
    return request.app.state.store


def get_inspector(request: Request) -> Inspector:
    return request.app.state.inspector


StoreDep = Annotated[CatalogStore, Depends(get_store)]
InspectorDep = Annotated[Inspector, Depends(get_inspector)]


async def require_auth(
    settings: SettingsDep,
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    """No-op unless CATALOG_TOKEN is configured (multi-user future)."""
    if not settings.token:
        return
    expected = f"Bearer {settings.token}"
    if not secrets.compare_digest(authorization or "", expected):
        raise HTTPException(status_code=401, detail="invalid or missing bearer token")


async def run_inspect(fn, *args):
    return await run_in_threadpool(fn, *args)


# ---- short TTL cache over the resolver hot path --------------------------

_resolve_cache: dict[str, tuple[float, CanonicalContainer]] = {}
# Bound the cache so a long-lived process can't grow it without limit (e.g.
# probes for ids that no longer exist). Far above any real workspace count.
_RESOLVE_CACHE_MAX = 512


async def resolve_cached(
    inspector: Inspector, settings: Settings, ws_id: str
) -> CanonicalContainer:
    ttl = settings.resolve_cache_ttl
    now = time.monotonic()
    if ttl > 0:
        hit = _resolve_cache.get(ws_id)
        if hit and (now - hit[0]) < ttl:
            return hit[1]
    result = await run_in_threadpool(inspector.resolve, ws_id)
    if ttl > 0:
        # Opportunistically drop expired entries; hard-cap as a backstop.
        for k in [k for k, (t, _) in _resolve_cache.items() if now - t >= ttl]:
            _resolve_cache.pop(k, None)
        if len(_resolve_cache) >= _RESOLVE_CACHE_MAX:
            _resolve_cache.clear()
        _resolve_cache[ws_id] = (now, result)
    return result


def invalidate_resolve_cache(ws_id: str | None = None) -> None:
    if ws_id is None:
        _resolve_cache.clear()
    else:
        _resolve_cache.pop(ws_id, None)
