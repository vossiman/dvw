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


async def test_workspace_missing_from_status_is_unknown():
    def handler(request):
        if request.url.path == "/v1/containers/status":
            return httpx.Response(200, json=[])
        return ok_handler(request)
    ws = await make_client(handler).workspaces_with_status()
    assert all(w.liveness == "unknown" for w in ws)


async def test_inspect_and_orphans_return_dicts():
    c = make_client(ok_handler)
    assert (await c.inspect("alpha"))["cpu_pct"] == 1.5
    assert (await c.orphans())[0]["container_name"] == "old"


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
