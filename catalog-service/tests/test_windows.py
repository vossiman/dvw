"""Window snapshot collector — one exec, every window of the `work` session,
served as `windows_many()` / `GET /v1/containers/windows` (Task 1 of the
tree-view plan). Driven against the real DockerInspector with a fake docker
client, same conventions as test_resolver.py.
"""

from __future__ import annotations

from app.config import Settings
from app.docker_inspect import DockerInspector
from tests.test_resolver import FakeClient, FakeContainer


def _inspector(containers, monkeypatch):
    import app.docker_inspect as di

    monkeypatch.setattr(di.docker, "from_env", lambda timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="", resolve_cache_ttl=0))


SNAPSHOT = (
    "@1\twork\t1\t1754900000\t\tclaude\t2\n"          # active, not waiting
    "@2\tshell\t0\t1754890000\t1754899000\tbash\t2\n"  # waiting since epoch
    "@3\tlogs\t0\t1754880000\t\t\t2\n"                 # empty command field
)


def test_windows_many_parses_snapshot(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_windows=SNAPSHOT)
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.workspace_id == "ws-a" and ww.container_id == "c1"
    assert ww.attached == 2
    assert [w.window_id for w in ww.windows] == ["@1", "@2", "@3"]
    w1, w2, w3 = ww.windows
    assert w1.active and w1.command == "claude" and w1.waiting_since is None
    assert not w2.active and w2.waiting_since == 1754899000
    assert w3.command == "" and w3.activity == 1754880000


def test_windows_many_garbage_lines_skipped(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a",
                      tmux_windows="not\ttab\tenough\n@9\tok\t0\t1\t\tbash\t1\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert [w.window_id for w in ww.windows] == ["@9"]


def test_windows_many_exec_failure_fails_open(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_windows=None)
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.windows == [] and ww.attached == 0


def test_windows_many_skips_stopped_and_unmapped(monkeypatch):
    stopped = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", status="exited")
    unmapped = FakeContainer("c2", "n2", "u2", "/elsewhere")
    insp = _inspector([stopped, unmapped], monkeypatch)
    assert insp.windows_many() == []


def test_windows_many_bad_waiting_epoch_treated_not_waiting(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a",
                      tmux_windows="@1\twork\t1\t5\tbanana\tclaude\t1\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.windows[0].waiting_since is None
