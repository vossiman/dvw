from __future__ import annotations


def _create(client, ws_id="proj-git-main", repo="git@github.com:me/proj", branch="main"):
    return client.post(
        "/v1/workspaces",
        json={"id": ws_id, "repo": repo, "branch": branch},
    )


def test_create_get_list(client):
    r = _create(client)
    assert r.status_code == 201
    body = r.json()
    assert body["id"] == "proj-git-main"
    assert body["ide"] == "cursor"  # default from catalog defaults
    assert body["provider"] == "vossisrv"

    r = client.get("/v1/workspaces/proj-git-main")
    assert r.status_code == 200
    assert r.json()["repo"] == "git@github.com:me/proj"

    r = client.get("/v1/workspaces")
    assert [w["id"] for w in r.json()] == ["proj-git-main"]


def test_create_duplicate_409(client):
    _create(client)
    r = _create(client)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "conflict"


def test_get_missing_404_envelope(client):
    r = client.get("/v1/workspaces/nope")
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "not_found"
    assert "nope" in r.json()["error"]["message"]


def test_bad_id_422(client):
    r = client.post(
        "/v1/workspaces", json={"id": "bad id!", "repo": "x", "branch": "y"}
    )
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "validation_error"


def test_patch_updates_fields(client):
    _create(client)
    r = client.patch(
        "/v1/workspaces/proj-git-main",
        json={"branch": "dev", "uid": "default-pr-12345"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["branch"] == "dev"
    assert body["uid"] == "default-pr-12345"


def test_patch_devpod_state_opaque(client):
    _create(client)
    snap = {"uid": "default-pr-99", "anything": {"nested": [1, 2, 3]}}
    r = client.patch("/v1/workspaces/proj-git-main", json={"devpod_state": snap})
    assert r.status_code == 200
    assert r.json()["devpod_state"] == snap


def test_touch_bumps_mru(client):
    _create(client, ws_id="a")
    _create(client, ws_id="b")
    # b is newest; touch a so it becomes most-recent.
    client.post("/v1/workspaces/a/touch")
    ids = [w["id"] for w in client.get("/v1/workspaces").json()]
    assert ids[0] == "a"


def test_delete_idempotent(client):
    _create(client)
    assert client.delete("/v1/workspaces/proj-git-main").status_code == 204
    # second delete still 204 (idempotent, like catalog_workspace_remove)
    assert client.delete("/v1/workspaces/proj-git-main").status_code == 204
    assert client.get("/v1/workspaces/proj-git-main").status_code == 404


def test_persistence_across_store_reload(client, settings):
    _create(client)
    # A fresh store reads the same file -> survives a restart.
    from app.store import CatalogStore

    reloaded = CatalogStore(settings.catalog_path)
    assert reloaded.get_workspace("proj-git-main").repo == "git@github.com:me/proj"
