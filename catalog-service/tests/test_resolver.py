"""Resolver tie-break parity tests, driven against the real DockerInspector
with a fake docker client (no daemon needed). These pin the exact semantics
dvw relied on: bind-mount destination match + tmux `work` activity tie-break.
"""

from __future__ import annotations

from app.config import Settings
from app.docker_inspect import DockerInspector


class FakeExecResult:
    def __init__(self, exit_code, stdout: bytes | None):
        self.exit_code = exit_code
        self.output = (stdout, None)


class FakeContainer:
    def __init__(self, cid, name, uid, dest, status="running",
                 created="2026-01-01T00:00:00Z", tmux_work=None, source="/exists"):
        self.id = cid
        self.name = name
        self.status = status
        self.labels = {"dev.containers.id": uid} if uid else {}
        self.attrs = {
            "Mounts": [{"Destination": dest, "Source": source, "Type": "bind"}],
            "Created": created,
            "State": {"Pid": 0, "Status": status, "Running": status == "running"},
        }
        self._tmux_work = tmux_work

    def exec_run(self, cmd, demux=False):
        if self._tmux_work is None:
            return FakeExecResult(1, None)
        return FakeExecResult(0, f"work {self._tmux_work}\nother 123\n".encode())


class FakeContainers:
    def __init__(self, containers):
        self._containers = containers

    def list(self, all=False, filters=None):
        return self._containers

    def get(self, cid):
        return next(c for c in self._containers if c.id == cid)


class FakeClient:
    def __init__(self, containers):
        self.containers = FakeContainers(containers)

    def ping(self):
        return True


def _inspector(containers, monkeypatch):
    import app.docker_inspect as di

    monkeypatch.setattr(di.docker, "from_env", lambda timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="", resolve_cache_ttl=0))


def test_no_match_returns_null_container(monkeypatch):
    insp = _inspector([], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id is None


def test_single_match(monkeypatch):
    c = FakeContainer("c1", "name1", "uid-1", "/workspaces/ws-a", tmux_work=100)
    insp = _inspector([c], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id == "c1"
    assert r.devpod_uid == "uid-1"
    assert r.tmux_work_activity == 100


def test_scopes_by_destination_not_prefix(monkeypatch):
    # The collision bug: two workspaces sharing a 2-char slug prefix.
    a = FakeContainer("ca", "na", "uid-a", "/workspaces/devmachine-git", tmux_work=5)
    b = FakeContainer("cb", "nb", "uid-b", "/workspaces/devmachine-new-dvw", tmux_work=9)
    insp = _inspector([a, b], monkeypatch)
    assert insp.resolve("devmachine-git").container_id == "ca"
    assert insp.resolve("devmachine-new-dvw").container_id == "cb"


def test_sibling_tmux_tiebreak_highest_activity_wins(monkeypatch):
    # Two containers share /workspaces/ws-a (the sibling case the resolver
    # exists for). Highest tmux `work` activity wins; the other is a sibling.
    real = FakeContainer("c-real", "real", "uid-real", "/workspaces/ws-a", tmux_work=1780249054)
    orphan = FakeContainer("c-orphan", "orphan", "uid-orphan", "/workspaces/ws-a", tmux_work=None)
    insp = _inspector([orphan, real], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id == "c-real"
    assert r.tmux_work_activity == 1780249054
    assert r.sibling_ids == ["c-orphan"]


def test_running_beats_stopped_even_with_activity(monkeypatch):
    stopped = FakeContainer("c-stop", "s", "uid-s", "/workspaces/ws-a",
                            status="exited", tmux_work=999)
    running = FakeContainer("c-run", "r", "uid-r", "/workspaces/ws-a",
                            status="running", tmux_work=None)
    insp = _inspector([stopped, running], monkeypatch)
    assert insp.resolve("ws-a").container_id == "c-run"


def test_ambiguous_no_tmux_refuses(monkeypatch):
    # >=2 running candidates, NONE with a `work` tmux session -> the legacy
    # resolver refuses to guess (status 1). The service signals ambiguity and
    # picks nothing, rather than promoting the newest-created sibling.
    old = FakeContainer("c-old", "o", "uid-o", "/workspaces/ws-a",
                        created="2026-01-01T00:00:00Z", tmux_work=None)
    new = FakeContainer("c-new", "n", "uid-n", "/workspaces/ws-a",
                        created="2026-06-01T00:00:00Z", tmux_work=None)
    insp = _inspector([old, new], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id is None
    assert r.ambiguous is True
    assert set(r.sibling_ids) == {"c-old", "c-new"}


def test_created_time_breaker_only_among_tmux_bearers(monkeypatch):
    # Two running candidates that BOTH have a `work` session -> highest activity
    # wins; created-time only breaks ties within the tmux-bearing set.
    a = FakeContainer("c-a", "a", "uid-a", "/workspaces/ws-a", tmux_work=100)
    b = FakeContainer("c-b", "b", "uid-b", "/workspaces/ws-a", tmux_work=200)
    insp = _inspector([a, b], monkeypatch)
    assert insp.resolve("ws-a").container_id == "c-b"


def test_stopped_container_is_not_a_candidate(monkeypatch):
    # A stopped sibling must not even enter resolution (legacy `docker ps`, no -a).
    stopped = FakeContainer("c-stop", "s", "uid-s", "/workspaces/ws-a",
                            status="exited", tmux_work=None)
    running = FakeContainer("c-run", "r", "uid-r", "/workspaces/ws-a",
                            status="running", tmux_work=None)
    insp = _inspector([stopped, running], monkeypatch)
    # Only one *running* candidate -> chosen unconditionally, not ambiguous.
    r = insp.resolve("ws-a")
    assert r.container_id == "c-run"
    assert r.ambiguous is False


def test_status_many_and_stale(monkeypatch):
    alive = FakeContainer("c1", "n1", "u1", "/workspaces/a", source="/exists")
    stale = FakeContainer("c2", "n2", "u2", "/workspaces/b", source="/gone")
    insp = _inspector([alive, stale], monkeypatch)

    # /exists is a real dir here (cwd-relative check uses os.path.isdir on the
    # absolute source); patch isdir for determinism.
    import app.docker_inspect as di
    monkeypatch.setattr(di.os.path, "isdir", lambda p: p == "/exists")

    res = {s.id: s.liveness for s in insp.status_many(["a", "b", "c"])}
    assert res == {"a": "alive", "b": "stale", "c": "absent"}


def test_orphans(monkeypatch):
    known = FakeContainer("c1", "n1", "u1", "/workspaces/known")
    leaked = FakeContainer("c2", "n2", "u2", "/workspaces/leaked")
    insp = _inspector([known, leaked], monkeypatch)
    orphans = insp.orphans({"known"})
    assert [o.workspace_id for o in orphans] == ["leaked"]
