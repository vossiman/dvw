from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.blueprint_store import BlueprintStore
from app.config import Settings
from app.deps import (
    get_blueprint_store,
    get_inspector,
    get_settings,
    get_store,
    invalidate_resolve_cache,
)
from app.main import create_app
from app.models import (
    CanonicalContainer,
    ContainerInspect,
    Orphan,
    WaitingWindow,
    WorkspaceStatus,
    WorkspaceWindows,
)
from app.store import CatalogStore


class FakeInspector:
    """In-memory docker stand-in. Tests set `.resolutions` / `.statuses` etc."""

    def __init__(self):
        self.alive = True
        self.resolutions: dict[str, CanonicalContainer] = {}
        self.inspections: dict[str, ContainerInspect] = {}
        self.statuses: dict[str, WorkspaceStatus] = {}
        self._orphans: list[Orphan] = []
        self.sibling_map: dict[str, list] = {}
        self.waiting: list[WaitingWindow] = []
        self.window_lists: list[WorkspaceWindows] = []

    def ping(self) -> bool:
        return self.alive

    def resolve(self, ws_id: str) -> CanonicalContainer:
        return self.resolutions.get(ws_id, CanonicalContainer(workspace_id=ws_id))

    def inspect(self, ws_id: str) -> ContainerInspect:
        return self.inspections.get(ws_id, ContainerInspect(workspace_id=ws_id))

    def siblings(self, ws_id: str) -> list:
        return self.sibling_map.get(ws_id, [])

    def status_many(self, ids):
        return [
            self.statuses.get(i, WorkspaceStatus(id=i, liveness="absent")) for i in ids
        ]

    def orphans(self, catalog_ids):
        return self._orphans

    def waiting_windows(self) -> list:
        return self.waiting

    def windows_many(self) -> list:
        return self.window_lists


@pytest.fixture
def settings(tmp_path):
    return Settings(data_dir=tmp_path, docker_host="", token=None)


@pytest.fixture
def store(settings):
    return CatalogStore(settings.catalog_path)


@pytest.fixture
def blueprint_store(settings):
    return BlueprintStore(
        effective_path=settings.blueprint_path,
        custom_path=settings.blueprint_custom_path,
        meta_path=settings.blueprint_meta_path,
        legacy_backup_path=settings.blueprint_legacy_backup_path,
    )


@pytest.fixture
def inspector():
    return FakeInspector()


@pytest.fixture
def client(settings, store, blueprint_store, inspector):
    invalidate_resolve_cache()
    app = create_app()
    app.dependency_overrides[get_settings] = lambda: settings
    app.dependency_overrides[get_store] = lambda: store
    app.dependency_overrides[get_blueprint_store] = lambda: blueprint_store
    app.dependency_overrides[get_inspector] = lambda: inspector
    # No context manager => lifespan is skipped => no real DockerInspector is
    # constructed. Routers use the overridden deps above.
    return TestClient(app)
