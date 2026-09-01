from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from app import source
from app.source import SourcePullError


def _git(path: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(path), *args], check=True,
                   capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                        "HOME": str(path), "PATH": "/usr/bin:/bin"})


PIN = "ghcr.io/vossiman/devbox-base@sha256:" + "a" * 64
NEW_PIN = "ghcr.io/vossiman/devbox-base@sha256:" + "b" * 64


@pytest.fixture
def clone(tmp_path):
    """origin (bare) + clone with a committed devcontainer pin."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
    subprocess.run(["git", "-C", str(origin), "symbolic-ref", "HEAD", "refs/heads/main"], check=True)
    work = tmp_path / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)
    dc = work / ".devcontainer"
    dc.mkdir()
    (dc / "devcontainer.json").write_text(
        '{\n  // devbox\n  "image": "%s"\n}\n' % PIN)
    _git(work, "add", "-A")
    _git(work, "commit", "-qm", "seed")
    _git(work, "push", "-q", "origin", "HEAD:refs/heads/main")
    clone = tmp_path / "content"
    subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True)
    return clone


def test_read_absent_clone(tmp_path):
    src = source.read_source("ws", tmp_path / "nope")
    assert src.present is False and src.branch is None


def test_read_clean_clone(clone):
    src = source.read_source("ws", clone)
    assert src.present and src.branch == "main" and not src.dirty
    assert not src.detached and src.head
    assert src.committed_pin == PIN          # JSONC comment tolerated


def test_read_dirty_and_detached(clone):
    (clone / "x").write_text("x")
    assert source.read_source("ws", clone).dirty is True
    (clone / "x").unlink()
    _git(clone, "checkout", "-q", "--detach")
    src = source.read_source("ws", clone)
    assert src.detached is True and src.branch is None


def test_pull_fast_forwards(clone, tmp_path):
    seed = tmp_path / "seed"
    f = seed / ".devcontainer" / "devcontainer.json"
    f.write_text(f.read_text().replace(PIN, NEW_PIN))
    _git(seed, "commit", "-aqm", "bump")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    src = source.pull_source("ws", clone)
    assert src.committed_pin == NEW_PIN


def test_pull_refuses_dirty(clone):
    (clone / "y").write_text("y")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 409


def test_pull_refuses_detached(clone):
    _git(clone, "checkout", "-q", "--detach")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 409


def test_pull_absent_404(tmp_path):
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", tmp_path / "gone")
    assert e.value.status == 404


def test_pull_surfaces_git_stderr(clone, tmp_path):
    # Diverge: local commit + different origin commit -> ff-only fails.
    (clone / "local").write_text("l")
    _git(clone, "add", "-A"); _git(clone, "commit", "-qm", "local")
    seed = tmp_path / "seed"
    (seed / "remote").write_text("r")
    _git(seed, "add", "-A"); _git(seed, "commit", "-qm", "remote")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 502
