from __future__ import annotations

import os
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


def test_pull_refuses_dirty_tracked(clone):
    f = clone / ".devcontainer" / "devcontainer.json"
    f.write_text(f.read_text() + "\n")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 409


def test_untracked_files_do_not_block_the_pull(clone, tmp_path):
    (clone / "stray-note.md").write_text("y")
    src = source.read_source("ws", clone)
    assert src.dirty is True and src.dirty_tracked is False
    seed = tmp_path / "seed"
    f = seed / ".devcontainer" / "devcontainer.json"
    f.write_text(f.read_text().replace(PIN, NEW_PIN))
    _git(seed, "commit", "-aqm", "bump")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    assert source.pull_source("ws", clone).committed_pin == NEW_PIN


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


def test_credential_args_needs_an_executable_helper(tmp_path):
    assert source._credential_args(None) == []
    missing = tmp_path / "nope"
    assert source._credential_args(missing) == []
    plain = tmp_path / "not-exec"
    plain.write_text("#!/bin/sh\n")
    assert source._credential_args(plain) == []
    helper = tmp_path / "helper"
    helper.write_text("#!/bin/sh\n")
    helper.chmod(0o755)
    args = source._credential_args(helper)
    # The empty entry first, so the host user's own git config cannot decide
    # how the service authenticates.
    assert args == ["-c", "credential.helper=",
                    "-c", f"credential.helper={helper}"]


def test_pull_passes_the_helper_to_git(clone, tmp_path, monkeypatch):
    helper = tmp_path / "helper"
    helper.write_text("#!/bin/sh\n")
    helper.chmod(0o755)
    seen = {}
    real = source._git

    def spy(path, *args):
        if "pull" in args:
            seen["args"] = args
        return real(path, *args)

    monkeypatch.setattr(source, "_git", spy)
    source.pull_source("ws", clone, helper)
    assert seen["args"][:4] == ("-c", "credential.helper=",
                                "-c", f"credential.helper={helper}")


def test_git_never_prompts_for_credentials(clone, monkeypatch):
    seen = {}

    def spy_run(cmd, **kw):
        seen.update(kw.get("env") or {})
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(source.subprocess, "run", spy_run)
    source._git(clone, "status")
    # A daemon has no tty: a prompt is a hang, not a message.
    assert seen["GIT_TERMINAL_PROMPT"] == "0"


def test_git_child_gets_a_normal_umask(clone, monkeypatch):
    seen = {}

    def spy_run(cmd, **kw):
        seen.update(kw)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(source.subprocess, "run", spy_run)
    source._git(clone, "status")
    # The unit's UMask=0117 is for its socket; inherited by git it creates
    # object dirs with no execute bit and the next write into one fails.
    assert seen["umask"] == 0o022


def test_pull_creates_usable_object_dirs_under_a_restrictive_umask(
        clone, tmp_path):
    seed = tmp_path / "seed"
    (seed / "new-file").write_text("x" * 100)
    _git(seed, "add", "-A")
    _git(seed, "commit", "-qm", "adds an object")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    old = os.umask(0o117)
    try:
        source.pull_source("ws", clone)
    finally:
        os.umask(old)
    assert (clone / "new-file").is_file()
    for d in (clone / ".git" / "objects").iterdir():
        if d.is_dir():
            assert d.stat().st_mode & 0o111, f"{d.name} has no execute bit"
