from __future__ import annotations

import asyncio
import json

import pytest
from pydantic import ValidationError

from app.models import CATALOG_VERSION, Catalog, Workspace
from app.store import CatalogStore, ConflictError, NotFoundError


def test_rejects_future_schema_version():
    # A catalog written by a newer dvw-catalog must be refused, not loaded.
    with pytest.raises(ValidationError):
        Catalog.model_validate({"version": CATALOG_VERSION + 1})


def test_accepts_current_and_seed_versions():
    # Current schema and the version-0 empty seed both load fine.
    assert Catalog.model_validate({"version": CATALOG_VERSION}).version == CATALOG_VERSION
    assert Catalog.model_validate({"version": 0}).version == 0


def test_store_load_fails_on_future_schema_version(tmp_path):
    # Mirrors the legacy client's "fails loudly on future schema version":
    # CatalogStore._load validates on read, so a future-version file on disk
    # makes construction raise rather than silently operate.
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps({"version": CATALOG_VERSION + 1, "workspaces": [], "repos": []}))
    with pytest.raises(ValidationError):
        CatalogStore(path)


@pytest.mark.asyncio
async def test_atomic_write_no_tmp_left_behind(tmp_path):
    store = CatalogStore(tmp_path / "catalog.json")
    await store.add_workspace(Workspace(id="a", repo="r", branch="m"))
    # No leftover temp files from the tmp+rename dance.
    assert not list(tmp_path.glob(".catalog.json.*"))
    assert (tmp_path / "catalog.json").exists()


@pytest.mark.asyncio
async def test_written_file_is_valid_legacy_schema(tmp_path):
    store = CatalogStore(tmp_path / "catalog.json")
    await store.add_workspace(Workspace(id="a", repo="r", branch="m", uid="u1"))
    data = json.loads((tmp_path / "catalog.json").read_text())
    assert data["version"] == 1
    assert "defaults" in data and "workspaces" in data and "repos" in data
    assert data["workspaces"][0]["id"] == "a"


@pytest.mark.asyncio
async def test_duplicate_raises_conflict(tmp_path):
    store = CatalogStore(tmp_path / "catalog.json")
    await store.add_workspace(Workspace(id="a", repo="r", branch="m"))
    with pytest.raises(ConflictError):
        await store.add_workspace(Workspace(id="a", repo="r", branch="m"))


@pytest.mark.asyncio
async def test_patch_missing_raises_notfound(tmp_path):
    store = CatalogStore(tmp_path / "catalog.json")
    with pytest.raises(NotFoundError):
        await store.patch_workspace("nope", {"branch": "x"})


@pytest.mark.asyncio
async def test_concurrent_touch_serializes(tmp_path):
    store = CatalogStore(tmp_path / "catalog.json")
    for i in range(5):
        await store.add_workspace(Workspace(id=f"w{i}", repo="r", branch="m"))
    # Fire many concurrent writers; the lock must keep the file consistent.
    await asyncio.gather(*(store.touch_workspace(f"w{i}") for i in range(5)))
    data = json.loads((tmp_path / "catalog.json").read_text())
    assert len(data["workspaces"]) == 5
