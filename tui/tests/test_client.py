import httpx
import pytest

from dvw_tui.client import CatalogClient, CatalogError, Workspace

WORKSPACES = [
    {"id": "alpha", "repo": "git@github.com:vossiman/alpha.git", "branch": "main",
     "ide": "cursor", "provider": "vossisrv", "last_used_at": "2026-06-10T10:00:00Z"},
    {"id": "beta", "repo": "https://github.com/vossiman/beta.git", "branch": "dev",
     "ide": "ssh", "provider": "vossisrv", "last_used_at": "2026-06-09T10:00:00Z"},
]
STATUSES = [
    {"id": "alpha", "liveness": "alive", "container_id": "c1", "devpod_uid": "u1"},
    {"id": "beta", "liveness": "stopped", "container_id": None, "devpod_uid": None},
]


def make_client(handler) -> CatalogClient:
    return CatalogClient(socket_path="/dev/null",
                         transport=httpx.MockTransport(handler))


def ok_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path == "/v1/workspaces":
        return httpx.Response(200, json=WORKSPACES)
    if path == "/v1/containers/status":
        return httpx.Response(200, json=STATUSES)
    if path == "/v1/workspaces/alpha/inspect":
        return httpx.Response(200, json={"workspace_id": "alpha", "liveness": "alive",
                                         "cpu_pct": 1.5, "mem_bytes": 1024})
    if path == "/v1/containers/orphans":
        return httpx.Response(200, json=[{"container_id": "c9", "container_name": "old",
                                          "state": "exited", "mount_status": "alive"}])
    if path == "/v1/health":
        return httpx.Response(200, json={"status": "ok", "version": "1", "docker": True,
                                         "store_writable": True, "workspaces": 2})
    return httpx.Response(404, json={"detail": "nope"})


async def test_workspaces_parsed():
    ws = await make_client(ok_handler).workspaces()
    assert [w.id for w in ws] == ["alpha", "beta"]
    assert ws[0].ide == "cursor"


def test_short_repo_strips_github_prefixes():
    w = Workspace.from_api(WORKSPACES[0])
    assert w.short_repo == "vossiman/alpha"
    w2 = Workspace.from_api(WORKSPACES[1])
    assert w2.short_repo == "vossiman/beta"


async def test_workspaces_with_status_merges_liveness():
    ws = await make_client(ok_handler).workspaces_with_status()
    assert {w.id: w.liveness for w in ws} == {"alpha": "alive", "beta": "stopped"}


async def test_workspaces_with_status_merges_image_current():
    def handler(request):
        if request.url.path == "/v1/containers/status":
            return httpx.Response(200, json=[
                {"id": "alpha", "liveness": "alive", "image_current": False},
                {"id": "beta", "liveness": "stopped"},
            ])
        return ok_handler(request)
    ws = await make_client(handler).workspaces_with_status()
    by_id = {w.id: w for w in ws}
    assert by_id["alpha"].image_current is False
    assert by_id["beta"].image_current is None


async def test_workspace_missing_from_status_is_unknown():
    def handler(request):
        if request.url.path == "/v1/containers/status":
            return httpx.Response(200, json=[])
        return ok_handler(request)
    ws = await make_client(handler).workspaces_with_status()
    assert all(w.liveness == "unknown" for w in ws)


async def test_workspaces_with_status_merges_attached():
    def handler(request):
        if request.url.path == "/v1/containers/status":
            return httpx.Response(200, json=[
                {"id": "alpha", "liveness": "alive", "attached": 2},
                {"id": "beta", "liveness": "stopped"},
            ])
        return ok_handler(request)
    ws = await make_client(handler).workspaces_with_status()
    assert {w.id: w.attached for w in ws} == {"alpha": 2, "beta": 0}


async def test_workspaces_with_status_attached_defaults_to_zero_on_old_server():
    def handler(request):
        if request.url.path == "/v1/containers/status":
            return httpx.Response(200, json=[
                {"id": "alpha", "liveness": "alive"},
                {"id": "beta", "liveness": "stopped"},
            ])
        return ok_handler(request)
    ws = await make_client(handler).workspaces_with_status()
    assert all(w.attached == 0 for w in ws)


async def test_inspect_and_orphans_return_dicts():
    c = make_client(ok_handler)
    assert (await c.inspect("alpha"))["cpu_pct"] == 1.5
    assert (await c.orphans())[0]["container_name"] == "old"


async def test_repos_returns_urls():
    def handler(request):
        if request.url.path == "/v1/repos":
            return httpx.Response(200, json=[
                {"url": "git@github.com:v/a.git", "last_branch": "main"}])
        return ok_handler(request)
    c = make_client(handler)
    assert await c.repos() == ["git@github.com:v/a.git"]


async def test_transport_error_raises_catalog_error():
    def handler(request):
        raise httpx.ConnectError("boom")
    with pytest.raises(CatalogError):
        await make_client(handler).workspaces()


async def test_http_error_raises_catalog_error():
    def handler(request):
        return httpx.Response(500, json={"detail": "kaput"})
    with pytest.raises(CatalogError):
        await make_client(handler).workspaces()


async def test_bearer_token_header_sent():
    seen = {}
    def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json=[])
    c = CatalogClient(socket_path="/dev/null", token="sekrit",
                      transport=httpx.MockTransport(handler))
    await c.workspaces()
    assert seen["auth"] == "Bearer sekrit"


WINDOWS = [
    {"workspace_id": "alpha", "container_id": "c1", "attached": 1,
     "windows": [
         {"window_id": "@1", "name": "shell", "active": True, "activity": 1754800100,
          "waiting_since": None, "command": "bash"},
         {"window_id": "@2", "name": "claude", "active": False, "activity": 1754800000,
          "waiting_since": 1754800000, "command": "claude"},
     ]},
    {"workspace_id": "beta", "container_id": "c2", "attached": 0,
     "windows": [
         {"window_id": "@1", "name": "shell", "active": True, "activity": 1754790000,
          "waiting_since": None, "command": "bash"},
     ]},
]


@pytest.mark.asyncio
async def test_windows_parses_nested_fields():
    def handler(request):
        assert request.url.path == "/v1/containers/windows"
        return httpx.Response(200, json=WINDOWS)
    result = await make_client(handler).windows()
    assert set(result) == {"alpha", "beta"}
    alpha = result["alpha"]
    assert alpha.workspace_id == "alpha"
    assert alpha.attached == 1
    assert not hasattr(alpha, "container_id")
    assert len(alpha.windows) == 2
    w1, w2 = alpha.windows
    assert w1.window_id == "@1" and w1.name == "shell" and w1.active is True
    assert w1.activity == 1754800100 and w1.waiting_since is None and w1.command == "bash"
    assert w2.waiting_since == 1754800000
    beta = result["beta"]
    assert beta.attached == 0
    assert len(beta.windows) == 1


@pytest.mark.asyncio
async def test_windows_fail_open_on_404_and_bad_body():
    async def check(json_or_status):
        def handler(request):
            if isinstance(json_or_status, int):
                return httpx.Response(json_or_status, json={"detail": "x"})
            return httpx.Response(200, json=json_or_status)
        assert await make_client(handler).windows() == {}
    await check(404)
    await check(500)
    await check({"detail": "not a list"})


@pytest.mark.asyncio
async def test_windows_entry_missing_fields_gets_defaults():
    def handler(request):
        return httpx.Response(200, json=[
            {"workspace_id": "alpha"},  # no attached, no windows
        ])
    result = await make_client(handler).windows()
    assert result["alpha"].attached == 0
    assert result["alpha"].windows == []


@pytest.mark.asyncio
async def test_windows_malformed_window_entry_skipped():
    def handler(request):
        return httpx.Response(200, json=[
            {"workspace_id": "alpha", "attached": 1, "windows": [
                {"window_id": "@1", "name": "shell"},  # ok, defaults fill in
                "not a dict",
                {"name": "no id"},  # missing window_id → skipped
            ]},
        ])
    result = await make_client(handler).windows()
    windows = result["alpha"].windows
    assert len(windows) == 1
    assert windows[0].window_id == "@1"
    assert windows[0].name == "shell"
    assert windows[0].active is False
    assert windows[0].activity == -1
    assert windows[0].command == ""


@pytest.mark.asyncio
async def test_windows_omits_duplicate_workspace_snapshots_from_old_server():
    def handler(request):
        return httpx.Response(200, json=[
            {"workspace_id": "alpha", "container_id": "canonical", "windows": [
                {"window_id": "@1", "name": "real"},
            ]},
            {"workspace_id": "alpha", "container_id": "sibling", "windows": [
                {"window_id": "@9", "name": "wrong"},
            ]},
        ])

    # The client cannot reproduce server-side tmux resolution, so the only
    # safe compatibility behavior is to omit an ambiguous duplicate entirely.
    assert await make_client(handler).windows() == {}
