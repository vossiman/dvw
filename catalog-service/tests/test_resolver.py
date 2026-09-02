"""Resolver tie-break parity tests, driven against the real DockerInspector
with a fake docker client (no daemon needed). These pin the exact semantics
dvw relied on: bind-mount destination match + tmux `work` activity tie-break.
"""

from __future__ import annotations

import time

from app.config import Settings
from app.docker_inspect import DockerInspector


class FakeExecResult:
    def __init__(self, exit_code, stdout: bytes | None):
        self.exit_code = exit_code
        self.output = (stdout, None)


class FakeContainer:
    def __init__(self, cid, name, uid, dest, status="running",
                 created="2026-01-01T00:00:00Z", tmux_work=None, source="/exists",
                 owner="codespace:codespace", tmux_attached=None,
                 tmux_windows=None, probe=None, probe_exit=None):
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
        self._owner = owner
        self._tmux_attached = tmux_attached
        self._tmux_windows = tmux_windows
        self._probe = probe
        self._probe_exit = probe_exit
        self.exec_calls = []

    def reload(self):
        return None

    def exec_run(self, cmd, demux=False):
        self.exec_calls.append(list(cmd))
        # `dvw-probe`: the single-exec snapshot. Default (probe=None,
        # probe_exit=None) is "not installed": exit 127, so every legacy test
        # keeps exercising the tmux fallback unchanged.
        if cmd == ["dvw-probe"]:
            if self._probe_exit is not None:
                return FakeExecResult(self._probe_exit, b"")
            if self._probe is None:
                return FakeExecResult(127, b"exec: dvw-probe: not found")
            import json as _json
            return FakeExecResult(0, _json.dumps(self._probe).encode())
        # `stat -c %U:%G /workspaces` — owner probe used to tell a provisioned
        # container from one abandoned before setup-user ran.
        if cmd and cmd[0] == "stat":
            if self._owner is None:
                return FakeExecResult(1, None)
            return FakeExecResult(0, f"{self._owner}\n".encode())
        # windows_many's single-exec snapshot: discriminated by
        # "pane_current_command" in the format string so it stays distinct
        # from the waiting-probe format below (rewired in Task 2).
        if cmd and "pane_current_command" in (cmd[-1] if cmd else ""):
            if self._tmux_windows is None:
                return FakeExecResult(1, None)
            return FakeExecResult(0, self._tmux_windows.encode())
        if cmd and "session_attached" in cmd[-1]:
            if self._tmux_attached is None:
                return FakeExecResult(1, None)
            return FakeExecResult(0, f"work {self._tmux_attached}\nother 0\n".encode())
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

    monkeypatch.setattr(di.docker, "DockerClient", lambda base_url=None, timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="unix:/nonexistent", resolve_cache_ttl=0))


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


class FakeImage:
    def __init__(self, repo_digests):
        self.attrs = {"RepoDigests": repo_digests}


def _digest_container(config_image, repo_digests=None):
    c = FakeContainer("c1", "name1", "uid-1", "/workspaces/ws-a")
    c.attrs["Config"] = {"Image": config_image}
    c.image = FakeImage(repo_digests or []) if repo_digests is not None else None
    return c


def test_image_digest_accepts_pinned_ref(monkeypatch):
    # Config.Image is a real pinned ref ("repo@sha256:..."); trust it.
    digest = "a" * 64
    c = _digest_container(f"ghcr.io/x/y@sha256:{digest}")
    insp = _inspector([c], monkeypatch)
    assert insp._image_digest(c) == f"sha256:{digest}"


def test_image_digest_rejects_bare_image_id(monkeypatch):
    # A container created straight from an image ID (no ref) stores a bare
    # "sha256:<hex>" in Config.Image: that's the image's own id, not a
    # manifest digest, and must never be trusted as one (permanent false
    # "outdated" otherwise). Falls through to RepoDigests instead.
    image_id = "b" * 64
    repo_digest = "c" * 64
    c = _digest_container(f"sha256:{image_id}", [f"ghcr.io/x/y@sha256:{repo_digest}"])
    insp = _inspector([c], monkeypatch)
    assert insp._image_digest(c) == f"sha256:{repo_digest}"


def test_image_digest_bare_image_id_no_repo_digests_is_unknown(monkeypatch):
    image_id = "d" * 64
    c = _digest_container(f"sha256:{image_id}", [])
    insp = _inspector([c], monkeypatch)
    assert insp._image_digest(c) is None


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


def test_status_many_reports_duplicate_running_siblings(monkeypatch):
    # Two RUNNING containers on one destination: status_many still picks a
    # winner, but must no longer hide that a duplicate exists — that silence is
    # how `dvw status`/`doctor` showed `running` while connect refused the same
    # workspace as ambiguous.
    a = FakeContainer("c-a", "a", "uid-a", "/workspaces/ws-a", status="running")
    b = FakeContainer("c-b", "b", "uid-b", "/workspaces/ws-a", status="running")
    insp = _inspector([a, b], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.running_siblings == 2
    assert st.container_id in {"c-a", "c-b"}


def test_status_many_single_running_has_one_sibling(monkeypatch):
    a = FakeContainer("c-a", "a", "uid-a", "/workspaces/ws-a", status="running")
    insp = _inspector([a], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.running_siblings == 1


def test_status_many_stopped_and_absent_report_zero_siblings(monkeypatch):
    stopped = FakeContainer("c-s", "s", "uid-s", "/workspaces/ws-a", status="exited")
    insp = _inspector([stopped], monkeypatch)
    st_by_id = {s.id: s for s in insp.status_many(["ws-a", "ws-missing"])}
    assert st_by_id["ws-a"].running_siblings == 0
    assert st_by_id["ws-a"].liveness == "stopped"
    assert st_by_id["ws-missing"].running_siblings == 0
    assert st_by_id["ws-missing"].liveness == "absent"


def test_siblings_reports_what_distinguishes_a_dud(monkeypatch):
    # The 2026-07-26 shape: two running containers, one provisioned with a live
    # `work` session, one abandoned before setup-user chowned /workspaces. The
    # owner probe now stats the bind-mount Source host-side rather than
    # exec'ing "stat" in the container, so stub os.stat/pwd/grp instead of
    # FakeContainer's exec_run.
    import grp
    import os
    import pwd

    real = FakeContainer("c-real", "elated_perlman", "uid-r", "/workspaces/ws-a",
                         tmux_work=555, source="/src/real")
    dud = FakeContainer("c-dud", "elated_wu", "uid-d", "/workspaces/ws-a",
                        tmux_work=None, source="/src/dud")
    insp = _inspector([real, dud], monkeypatch)

    class FakeStat:
        def __init__(self, uid, gid):
            self.st_uid = uid
            self.st_gid = gid

    stats = {"/src/real": FakeStat(1000, 1000), "/src/dud": FakeStat(0, 0)}
    monkeypatch.setattr(os, "stat", lambda p: stats[p])
    monkeypatch.setattr(
        pwd, "getpwuid",
        lambda uid: type("P", (), {"pw_name": "codespace" if uid else "root"})(),
    )
    monkeypatch.setattr(
        grp, "getgrgid",
        lambda gid: type("G", (), {"gr_name": "codespace" if gid else "root"})(),
    )

    by_id = {s.container_id: s for s in insp.siblings("ws-a")}
    assert set(by_id) == {"c-real", "c-dud"}
    assert by_id["c-real"].tmux_work_activity == 555
    assert by_id["c-real"].workspaces_owner == "codespace:codespace"
    assert by_id["c-dud"].tmux_work_activity == -1
    assert by_id["c-dud"].workspaces_owner == "root:root"
    assert by_id["c-dud"].container_name == "elated_wu"


def test_siblings_single_container_is_a_one_element_list(monkeypatch):
    c = FakeContainer("c1", "n1", "uid-1", "/workspaces/ws-a", tmux_work=1)
    insp = _inspector([c], monkeypatch)
    assert len(insp.siblings("ws-a")) == 1


def test_siblings_excludes_stopped_containers(monkeypatch):
    # Only RUNNING containers are candidates, so only they can be siblings.
    run = FakeContainer("c-run", "r", "uid-r", "/workspaces/ws-a", status="running")
    stop = FakeContainer("c-stop", "s", "uid-s", "/workspaces/ws-a", status="exited")
    insp = _inspector([run, stop], monkeypatch)
    assert [s.container_id for s in insp.siblings("ws-a")] == ["c-run"]


def test_siblings_tolerates_unreadable_owner(monkeypatch):
    # A container whose bind-mount Source can't be stat'd must not break the
    # listing.
    import os

    c = FakeContainer("c1", "n1", "uid-1", "/workspaces/ws-a", tmux_work=1,
                       source="/src/unreadable")

    def _raise(p):
        raise OSError("no such path")

    monkeypatch.setattr(os, "stat", _raise)
    insp = _inspector([c], monkeypatch)
    (s,) = insp.siblings("ws-a")
    assert s.workspaces_owner is None


def test_workspaces_owner_reads_host_side_without_exec(tmp_path, monkeypatch):
    """The owner probe must not call exec_run; it stats the bind-mount Source."""
    from app.config import Settings
    from app.docker_inspect import DockerInspector

    src = tmp_path / "ws"
    src.mkdir()

    class NoExec:
        status = "running"
        attrs = {"Mounts": [{"Destination": "/workspaces/demo",
                             "Source": str(src), "Type": "bind"}]}

        def exec_run(self, *a, **k):
            raise AssertionError("exec_run must not be called")

    inspector = DockerInspector.__new__(DockerInspector)
    inspector._settings = Settings(workspace_mount_prefix="/workspaces/")

    owner = inspector._workspaces_owner(NoExec())
    assert owner is not None
    assert ":" in owner


def test_workspaces_owner_reports_root_root_for_uid_zero(monkeypatch):
    """uid/gid 0 must still read as 'root:root' — the dud-sibling signal."""
    import os
    from app.config import Settings
    from app.docker_inspect import DockerInspector

    class C:
        status = "running"
        attrs = {"Mounts": [{"Destination": "/workspaces/demo",
                             "Source": "/nonexistent-but-stubbed", "Type": "bind"}]}

    class FakeStat:
        st_uid = 0
        st_gid = 0

    monkeypatch.setattr(os, "stat", lambda p: FakeStat())

    inspector = DockerInspector.__new__(DockerInspector)
    inspector._settings = Settings(workspace_mount_prefix="/workspaces/")
    assert inspector._workspaces_owner(C()) == "root:root"


def test_status_many_reports_attached_clients(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_attached=2)
    insp = _inspector([c], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 2


def test_status_many_attached_zero_when_no_work_session(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_attached=None)
    insp = _inspector([c], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 0


def test_status_many_attached_zero_for_stopped_and_absent(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", status="exited",
                      tmux_attached=3)
    insp = _inspector([c], monkeypatch)
    res = {s.id: s.attached for s in insp.status_many(["ws-a", "ws-gone"])}
    assert res == {"ws-a": 0, "ws-gone": 0}


def test_tmux_work_attached_garbage_output(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a")
    c.exec_run = lambda cmd, demux=False: FakeExecResult(0, b"work banana\n")
    insp = _inspector([c], monkeypatch)
    assert insp._tmux_work_attached(c) == 0


def test_tmux_work_attached_exec_raises(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a")
    def boom(cmd, demux=False):
        raise RuntimeError("docker died")
    c.exec_run = boom
    insp = _inspector([c], monkeypatch)
    assert insp._tmux_work_attached(c) == 0


def test_status_many_bounds_slow_attached_probe(monkeypatch):
    import app.docker_inspect as di

    monkeypatch.setattr(di.os.path, "isdir", lambda path: path == "/exists")
    slow = FakeContainer("slow", "slow", "u1", "/workspaces/slow")
    fast = FakeContainer("fast", "fast", "u2", "/workspaces/fast",
                         tmux_attached=3)
    original = slow.exec_run

    def delayed(cmd, demux=False):
        if cmd and "session_attached" in cmd[-1]:
            time.sleep(0.5)
        return original(cmd, demux=demux)

    slow.exec_run = delayed
    insp = _inspector([slow, fast], monkeypatch)
    insp._attached_probe_budget = 0.05

    started = time.monotonic()
    statuses = {s.id: s for s in insp.status_many(["slow", "fast", "missing"])}
    elapsed = time.monotonic() - started

    assert elapsed < 0.2
    assert statuses["slow"].liveness == "alive"
    assert statuses["slow"].attached == 0
    assert statuses["fast"].attached == 3
    assert statuses["missing"].liveness == "absent"


def test_status_many_attached_future_failure_fails_open(monkeypatch):
    import app.docker_inspect as di

    monkeypatch.setattr(di.os.path, "isdir", lambda path: path == "/exists")
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a")
    insp = _inspector([c], monkeypatch)
    monkeypatch.setattr(insp, "_tmux_work_attached",
                        lambda container: (_ for _ in ()).throw(RuntimeError("boom")))

    (status,) = insp.status_many(["ws-a"])
    assert status.liveness == "alive"
    assert status.attached == 0


def test_status_many_duplicate_siblings_report_canonical_container(monkeypatch):
    import app.docker_inspect as di

    monkeypatch.setattr(di.os.path, "isdir", lambda path: path == "/exists")
    canonical = FakeContainer("c-real", "real", "u-real", "/workspaces/ws-a",
                              tmux_work=200, tmux_attached=2)
    other = FakeContainer("c-other", "other", "u-other", "/workspaces/ws-a",
                          tmux_work=100, tmux_attached=5)
    # Noncanonical sibling listed first: the old first-listed pick would
    # report c-other's id and attached count while attach went to c-real.
    insp = _inspector([other, canonical], monkeypatch)

    assert insp.resolve("ws-a").container_id == "c-real"
    (status,) = insp.status_many(["ws-a"])
    assert status.liveness == "alive"
    assert status.container_id == "c-real"
    assert status.devpod_uid == "u-real"
    assert status.running_siblings == 2
    assert status.attached == 2


def test_repeated_slow_status_requests_do_not_queue_more_probes(monkeypatch):
    containers = [
        FakeContainer(f"c{i}", f"n{i}", f"u{i}", f"/workspaces/ws-{i}")
        for i in range(8)
    ]
    calls: list[str] = []
    for c in containers:
        original = c.exec_run

        def delayed(cmd, demux=False, *, container=c, run=original):
            if cmd and "session_attached" in cmd[-1]:
                calls.append(container.id)
                time.sleep(0.4)
            return run(cmd, demux=demux)

        c.exec_run = delayed

    insp = _inspector(containers, monkeypatch)
    insp._attached_probe_budget = 0.03
    ids = [f"ws-{i}" for i in range(8)]

    insp.status_many(ids)
    insp.status_many(ids)
    # Let the first four finish. A queued executor design would then start
    # later work; the slot-gated design never retained it.
    time.sleep(0.45)

    assert len(calls) == insp._attached_probe_workers
