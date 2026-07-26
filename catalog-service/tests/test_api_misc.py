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
    assert r.status_code == 200
    content = r.json()["content"]
    assert "Host *.devpod" in content
    assert "ServerAliveInterval 5" in content
    assert "ServerAliveCountMax 3" in content
    assert r.json()["managed_version"] == 2
    assert r.json()["migration_status"] == "fresh_initialized"
    assert r.json()["revision"].startswith("sha256:")
    assert r.headers["etag"] == f'"{r.json()["revision"]}"'
    assert r.json()["version"] > 0

    client.put("/v1/blueprint", json={"content": "Host foo\n  User bar\n"})
    r = client.get("/v1/blueprint")
    assert r.json()["content"].startswith("Host foo\n  User bar\n\n")
    assert "# BEGIN DVW MANAGED DEFAULTS version=2" in r.json()["content"]
    assert r.json()["version"] > 0


def test_blueprint_custom_endpoint_and_revision_guard(client):
    original = client.get("/v1/blueprint").json()
    custom = "Host *.devpod\n  ServerAliveInterval 10\n"
    r = client.put(
        "/v1/blueprint/custom",
        headers={"If-Match": f'"{original["revision"]}"'},
        json={"content": custom},
    )
    assert r.status_code == 200
    assert r.json()["content"] == custom
    assert r.json()["revision"] != original["revision"]

    effective = client.get("/v1/blueprint").json()["content"]
    assert effective.startswith(custom)
    assert effective.index("ServerAliveInterval 10") < effective.index(
        "ServerAliveInterval 5"
    )

    stale = client.put(
        "/v1/blueprint/custom",
        headers={"If-Match": f'"{original["revision"]}"'},
        json={"content": "Host stale\n"},
    )
    assert stale.status_code == 409
    assert "revision changed" in stale.json()["error"]["message"]


def test_blueprint_rejects_modified_managed_section(client):
    effective = client.get("/v1/blueprint").json()["content"]
    modified = effective.replace("ControlPersist 10m", "ControlPersist 1h")
    r = client.put("/v1/blueprint", json={"content": modified})
    assert r.status_code == 409
    assert "managed SSH section cannot be edited" in r.json()["error"]["message"]


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
                         "container_id": "c1", "devpod_uid": None,
                         "running_siblings": 0}]


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


def test_workspace_siblings_endpoint(client, inspector):
    from app.models import SiblingContainer

    inspector.sibling_map["ws-a"] = [
        SiblingContainer(container_id="c-real", container_name="perlman",
                         state="running", tmux_work_activity=555,
                         workspaces_owner="codespace:codespace"),
        SiblingContainer(container_id="c-dud", container_name="wu",
                         state="running", tmux_work_activity=-1,
                         workspaces_owner="root:root"),
    ]
    r = client.get("/v1/workspaces/ws-a/siblings")
    assert r.status_code == 200
    body = {s["container_id"]: s for s in r.json()}
    assert body["c-dud"]["workspaces_owner"] == "root:root"
    assert body["c-dud"]["tmux_work_activity"] == -1
    assert body["c-real"]["tmux_work_activity"] == 555


def test_workspace_siblings_empty_when_no_containers(client, inspector):
    r = client.get("/v1/workspaces/ws-none/siblings")
    assert r.status_code == 200
    assert r.json() == []
