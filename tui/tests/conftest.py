import pytest

from dvw_tui.client import CatalogError, Workspace


class FakeClient:
    """In-memory stand-in for CatalogClient. Set .fail=True to simulate
    an unreachable catalog."""

    def __init__(self):
        self.fail = False
        self.inspect_calls = []
        self._workspaces = [
            Workspace(id="alpha", repo="git@github.com:vossiman/alpha.git",
                      branch="main", ide="cursor", provider="vossisrv",
                      last_used_at="2026-06-10T10:00:00Z", liveness="alive"),
            Workspace(id="beta", repo="git@github.com:vossiman/beta.git",
                      branch="dev", ide="ssh", provider="vossisrv",
                      last_used_at="2026-06-09T10:00:00Z", liveness="stopped"),
        ]
        self._inspect = {
            "alpha": {"workspace_id": "alpha", "container_name": "devpod-alpha",
                      "status": "running", "health": None, "image": "img:1",
                      "started_at": "2026-06-10T09:00:00Z", "restart_count": 0,
                      "cpu_pct": 12.0, "mem_bytes": 1024**3, "mem_limit": 4 * 1024**3,
                      "mem_pct": 25.0, "disk_bytes": 2 * 1024**3, "liveness": "alive",
                      "bind_mounts": [{"source": "/home/x", "destination": "/workspaces/alpha", "rw": True}]},
            "beta": {"workspace_id": "beta", "container_name": "devpod-beta",
                     "status": "exited", "liveness": "stopped", "bind_mounts": []},
        }
        self._orphans = [
            {"container_id": "c9", "container_name": "devpod-old", "devpod_uid": "u9",
             "workspace_id": "old", "state": "exited", "mount_status": "alive",
             "mount_source": "/home/old"},
        ]

    def _check(self):
        if self.fail:
            raise CatalogError("connection refused")

    async def workspaces_with_status(self):
        self._check()
        return list(self._workspaces)

    async def inspect(self, workspace_id):
        self.inspect_calls.append(workspace_id)
        self._check()
        return self._inspect[workspace_id]

    async def orphans(self):
        self._check()
        return list(self._orphans)

    async def health(self):
        self._check()
        return {"status": "ok", "version": "1", "docker": True,
                "store_writable": True, "workspaces": len(self._workspaces)}

    async def aclose(self):
        pass


@pytest.fixture
def fake_client():
    return FakeClient()
