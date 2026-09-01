from __future__ import annotations

import subprocess

import pytest


def _create(client, ws_id="proj"):
    return client.post("/v1/workspaces", json={
        "id": ws_id, "repo": "git@github.com:me/proj", "branch": "main"})


def _seed_clone(settings, ws_id="proj"):
    """A real git repo (with origin) at settings.source_path(ws_id)."""
    path = settings.source_path(ws_id)
    origin = path.parent / "origin.git"
    origin.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "--bare", "-q", "-b", "main", str(origin)], check=True)
    seed = path.parent / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True)
    (seed / "f").write_text("f")
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
           "PATH": "/usr/bin:/bin"}
    subprocess.run(["git", "-C", str(seed), "add", "-A"], check=True, env=env)
    subprocess.run(["git", "-C", str(seed), "commit", "-qm", "s"],
                   check=True, env=env)
    subprocess.run(["git", "-C", str(seed), "push", "-q", "origin",
                    "HEAD:refs/heads/main"], check=True)
    subprocess.run(["git", "clone", "-q", str(origin), str(path)], check=True)
    return path


def test_source_absent_clone_is_present_false(client):
    _create(client)
    r = client.get("/v1/workspaces/proj/source")
    assert r.status_code == 200
    assert r.json()["present"] is False


def test_source_unknown_workspace_404(client):
    assert client.get("/v1/workspaces/nope/source").status_code == 404


def test_source_reads_clone(client, settings):
    _create(client)
    _seed_clone(settings)
    body = client.get("/v1/workspaces/proj/source").json()
    assert body["present"] is True and body["branch"] == "main"


def test_pull_dirty_409(client, settings):
    _create(client)
    path = _seed_clone(settings)
    (path / "dirt").write_text("d")
    r = client.post("/v1/workspaces/proj/source/pull")
    assert r.status_code == 409
    assert "uncommitted" in r.text


def test_pull_ok(client, settings):
    _create(client)
    _seed_clone(settings)
    r = client.post("/v1/workspaces/proj/source/pull")
    assert r.status_code == 200 and r.json()["present"] is True


def test_source_path_rejects_traversal(settings):
    # The route pattern allows "." and "-" in ws_id, so ".." is a legal
    # string as far as FastAPI's path validation goes; source_path() must
    # itself refuse anything that resolves outside the agent workspaces dir.
    with pytest.raises(ValueError):
        settings.source_path("..")


def test_source_path_rejects_nested_traversal(settings):
    with pytest.raises(ValueError):
        settings.source_path("../../etc")


def test_source_path_accepts_normal_id(settings):
    p = settings.source_path("proj")
    assert p == (settings.devpod_agent_workspaces_dir.expanduser().resolve()
                 / "proj" / "content")
