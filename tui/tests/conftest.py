import pytest

from dvw_tui import actions
from dvw_tui.actions import ActionResult
from dvw_tui.client import (
    CatalogError,
    Workspace,
    WindowInfo,
    WorkspaceWindows,
)


class FakeClient:
    """In-memory stand-in for CatalogClient. Set .fail=True to simulate
    an unreachable catalog."""

    def __init__(self):
        self.fail = False
        self.inspect_calls = []
        # tmux window snapshot, shaped like GET /v1/containers/windows.
        # alpha (running) has two windows, the first one @waiting; beta
        # (stopped) has none — the tree's two shapes in one fixture.
        self.window_map: dict[str, WorkspaceWindows] = {
            "alpha": WorkspaceWindows(
                workspace_id="alpha",
                attached=2,
                windows=[
                    WindowInfo(window_id="@1", name="claude", active=True,
                               activity=1754800000, waiting_since=1754800000,
                               command="claude"),
                    WindowInfo(window_id="@2", name="shell", active=False,
                               activity=1754799000, command="bash"),
                ],
            ),
        }
        # Global catalog defaults, shaped like GET /v1/defaults. Tests mutate
        # this to exercise the wizard's IDE preselection.
        self.defaults_body = {"ide": "cursor", "provider": "vossisrv"}
        self._workspaces = [
            Workspace(id="alpha", repo="git@github.com:vossiman/alpha.git",
                      branch="main", ide="cursor", provider="vossisrv",
                      last_used_at="2026-06-10T10:00:00Z", liveness="alive",
                      attached=2),
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

    async def repos(self):
        self._check()
        # Deliberately a different form than fake_new_cli's --list-branches
        # resolved URL (git@…) — proves the wizard adopts the RESOLVED
        # value from `dvw new --list-branches`, not the catalog entry
        # picked from the OptionList.
        return ["https://github.com/vossiman/alpha.git",
                "https://github.com/vossiman/beta.git"]

    async def defaults(self):
        self._check()
        return dict(self.defaults_body)

    async def windows(self):
        # Mirrors the real client's fail-open degradation: errors yield {}
        # rather than raising CatalogError.
        if self.fail:
            return {}
        return dict(self.window_map)

    async def health(self):
        self._check()
        return {"status": "ok", "version": "1", "docker": True,
                "store_writable": True, "workspaces": len(self._workspaces)}

    async def aclose(self):
        pass


@pytest.fixture
def fake_client():
    return FakeClient()


@pytest.fixture
def fake_new_cli(monkeypatch):
    """Canned `dvw new --list-branches/--check-devcontainer` results.

    Monkeypatches actions.run_captured_split (the split-capture path the
    wizard uses) so the wizard's subprocess calls resolve instantly. Tests
    mutate state["branches"]/["devcontainer_rc"] before driving the pilot;
    state["calls"] records every argv.
    """
    state = {"branches": (0, "git@github.com:vossiman/alpha.git\nmain\ndev\n"),
             "devcontainer_rc": 0, "calls": []}

    def fake_run_captured(argv):
        state["calls"].append(argv)
        if "--list-branches" in argv:
            rc, out = state["branches"]
            return ActionResult(ok=rc == 0, returncode=rc, output=out)
        if "--check-devcontainer" in argv:
            rc = state["devcontainer_rc"]
            return ActionResult(ok=rc == 0, returncode=rc, output="")
        raise AssertionError(f"unexpected argv: {argv}")

    monkeypatch.setattr(actions, "run_captured_split", fake_run_captured)
    return state
