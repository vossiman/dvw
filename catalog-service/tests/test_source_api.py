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


def test_pull_dirty_tracked_409(client, settings):
    _create(client)
    path = _seed_clone(settings)
    (path / "f").write_text("edited")
    r = client.post("/v1/workspaces/proj/source/pull")
    assert r.status_code == 409
    assert "uncommitted" in r.text


def test_pull_ignores_untracked(client, settings):
    _create(client)
    path = _seed_clone(settings)
    (path / "dirt").write_text("d")
    assert client.post("/v1/workspaces/proj/source/pull").status_code == 200
    body = client.get("/v1/workspaces/proj/source").json()
    assert body["dirty"] is True and body["dirty_tracked"] is False


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


def _commit_pin(path, image, *, commit=True):
    (path / ".devcontainer").mkdir(exist_ok=True)
    (path / ".devcontainer" / "devcontainer.json").write_text(f'{{"image": "{image}"}}')
    if commit:
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
               "PATH": "/usr/bin:/bin"}
        subprocess.run(["git", "-C", str(path), "add", "-A"], check=True, env=env)
        subprocess.run(["git", "-C", str(path), "commit", "-qm", "pin"],
                       check=True, env=env)


OLD = "ghcr.io/x/devbox-base@sha256:" + "a" * 64
NEW = "ghcr.io/x/devbox-base@sha256:" + "b" * 64


def _pin_current(client):
    return client.get("/v1/containers/status").json()[0]["pin_current"]


def test_status_pin_current_compares_committed_pin(client, settings, blueprint_image):
    blueprint_image.value = NEW
    _create(client)
    path = _seed_clone(settings)
    assert _pin_current(client) is None          # no devcontainer.json
    _commit_pin(path, OLD)
    assert _pin_current(client) is False
    _commit_pin(path, NEW)
    assert _pin_current(client) is True


def test_status_pin_current_ignores_uncommitted_boot_sync_rewrite(
        client, settings, blueprint_image):
    blueprint_image.value = NEW
    _create(client)
    path = _seed_clone(settings)
    _commit_pin(path, OLD)
    _commit_pin(path, NEW, commit=False)
    assert _pin_current(client) is False


def test_status_pin_current_unknown_without_blueprint_or_clone(
        client, settings, blueprint_image):
    _create(client)
    assert _pin_current(client) is None          # no clone
    path = _seed_clone(settings)
    _commit_pin(path, OLD)
    assert _pin_current(client) is None          # blueprint unknown
