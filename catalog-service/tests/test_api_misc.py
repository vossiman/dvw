from __future__ import annotations

from app.models import CanonicalContainer, Orphan, WorkspaceStatus


def test_health(client, inspector):
    r = client.get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["docker"] is True
    assert body["store_writable"] is True
    assert body["workspaces"] == 0


def test_health_reports_docker_down(client, inspector):
    inspector.alive = False
    assert client.get("/v1/health").json()["docker"] is False


def test_defaults_get_update(client):
    assert client.get("/v1/defaults").json() == {"ide": "cursor", "provider": "vossisrv"}
    r = client.put("/v1/defaults", json={"ide": "vscode"})
    assert r.json()["ide"] == "vscode"
    assert client.get("/v1/defaults").json()["provider"] == "vossisrv"


def test_repos_upsert_list_mru(client):
    client.post("/v1/repos", json={"url": "u1", "last_branch": "main"})
    client.post("/v1/repos", json={"url": "u2", "last_branch": "dev"})
    client.post("/v1/repos", json={"url": "u1", "last_branch": "feature"})  # update
    urls = [r["url"] for r in client.get("/v1/repos").json()]
    assert urls[0] == "u1"  # u1 touched most recently
    r = client.get("/v1/repos/by-url", params={"url": "u1"})
    assert r.json()["last_branch"] == "feature"


def test_blueprint_seed_then_update(client):
    r = client.get("/v1/blueprint")
    assert "Host *.devpod" in r.json()["content"]
    assert r.json()["version"] == 0  # seed, no file yet

    client.put("/v1/blueprint", json={"content": "Host foo\n  User bar\n"})
    r = client.get("/v1/blueprint")
    assert r.json()["content"] == "Host foo\n  User bar\n"
    assert r.json()["version"] > 0


def test_resolve_endpoint(client, inspector):
    inspector.resolutions["ws-a"] = CanonicalContainer(
        workspace_id="ws-a", container_id="c1", devpod_uid="uid-1", state="running"
    )
    r = client.get("/v1/workspaces/ws-a/container")
    assert r.json()["container_id"] == "c1"
    assert r.json()["devpod_uid"] == "uid-1"


def test_containers_status_defaults_to_all(client, inspector):
    client.post("/v1/workspaces", json={"id": "a", "repo": "r", "branch": "m"})
    inspector.statuses["a"] = WorkspaceStatus(id="a", liveness="alive", container_id="c1")
    r = client.get("/v1/containers/status")
    assert r.json() == [{"id": "a", "liveness": "alive",
                         "container_id": "c1", "devpod_uid": None}]


def test_containers_orphans(client, inspector):
    inspector._orphans = [Orphan(container_id="c9", workspace_id="leaked",
                                 mount_status="deleted")]
    r = client.get("/v1/containers/orphans")
    assert r.json()[0]["workspace_id"] == "leaked"


def test_catalog_full_dump(client):
    client.post("/v1/workspaces", json={"id": "a", "repo": "r", "branch": "m"})
    cat = client.get("/v1/catalog").json()
    assert cat["version"] == 1
    assert cat["defaults"]["provider"] == "vossisrv"
    assert [w["id"] for w in cat["workspaces"]] == ["a"]
