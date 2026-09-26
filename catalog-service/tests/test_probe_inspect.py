"""docker_inspect gets everything from one dvw-probe exec per container per
call. A container without the probe (exit 126/127) reports "missing" with an
empty snapshot; there is no tmux fallback."""

from __future__ import annotations

from app.config import Settings
from app.docker_inspect import DockerInspector
from tests.test_probe import GOOD
from tests.test_resolver import FakeClient, FakeContainer


def _inspector(containers, monkeypatch):
    import app.docker_inspect as di
    monkeypatch.setattr(di.docker, "DockerClient", lambda base_url=None, timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="unix:/nonexistent", resolve_cache_ttl=0))


def _probe_container(cid="c1", ws="ws-a", **kw):
    return FakeContainer(cid, f"n-{cid}", f"u-{cid}", f"/workspaces/{ws}", probe=GOOD, **kw)


def test_windows_many_uses_probe_once(monkeypatch):
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.attached == 1
    assert [w.window_id for w in ww.windows] == ["@7", "@8"]
    assert ww.windows[1].waiting_since == 1756795000
    execs = [cmd for cmd in c.exec_calls if cmd == ["dvw-probe"]]
    assert len(execs) == 1
    assert not any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_status_many_attached_from_probe(monkeypatch):
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 1
    assert sum(1 for cmd in c.exec_calls if cmd == ["dvw-probe"]) == 1


def test_status_many_siblings_reuse_the_tiebreak_snapshot(monkeypatch):
    # The tie-break already exec'd both siblings; the attached fan-out must
    # not exec the winner a second time within the same request.
    a = FakeContainer("c-a", "a", "u-a", "/workspaces/ws-a", probe=GOOD)
    quiet = {**GOOD, "tmux": {"sessions": [{"name": "work", "attached": 0, "activity": 10}],
                              "windows": []}}
    b = FakeContainer("c-b", "b", "u-b", "/workspaces/ws-a", probe=quiet)
    insp = _inspector([a, b], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.container_id == "c-a" and st.attached == 1
    assert sum(1 for cmd in a.exec_calls if cmd == ["dvw-probe"]) == 1
    assert sum(1 for cmd in b.exec_calls if cmd == ["dvw-probe"]) == 1


def test_inspect_execs_once_per_request(monkeypatch):
    # resolve() inside inspect() and the snapshot share one memo.
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    insp.inspect("ws-a")
    assert sum(1 for cmd in c.exec_calls if cmd == ["dvw-probe"]) == 1


def test_sibling_tiebreak_uses_probe_activity(monkeypatch):
    quiet = {**GOOD, "tmux": {"sessions": [{"name": "work", "attached": 0, "activity": 10}], "windows": []}}
    a = FakeContainer("c-a", "a", "u-a", "/workspaces/ws-a", probe=quiet)
    b = FakeContainer("c-b", "b", "u-b", "/workspaces/ws-a", probe=GOOD)
    insp = _inspector([a, b], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id == "c-b" and r.tmux_work_activity == 1756799990


def test_probe_failure_is_not_a_fallback(monkeypatch):
    # exit 1 means the probe exists but broke: no tmux exec, empty snapshot.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", probe_exit=1,
                      tmux_work=100, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.windows == [] and ww.attached == 0
    assert not any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_inspect_carries_agents_git_and_probe_state(monkeypatch):
    c = _probe_container()
    c.attrs["Config"] = {"Image": "ghcr.io/x/y@sha256:" + "a" * 64}
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.probe == "ok"
    assert info.agents[0].cli == "claude" and info.agents[0].pid == 4242
    assert info.git.branch == "feat/x" and info.git.dirty is True and info.git.ahead == 2
    assert info.image == "ghcr.io/x/y@sha256:" + "a" * 64


def test_inspect_probe_missing_state(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a")
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.probe == "missing" and info.agents == [] and info.git is None
    assert c.exec_calls == [["dvw-probe"]]


def test_probe_missing_is_reported_not_worked_around(monkeypatch):
    # No tmux fallback: a container without dvw-probe costs exactly one exec
    # per call and answers with the empty snapshot, whoever asks.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.windows == [] and ww.attached == 0
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 0
    assert insp.resolve("ws-a").tmux_work_activity == -1
    assert insp._attached_many([c]) == {"c1": 0}
    assert all(cmd == ["dvw-probe"] for cmd in c.exec_calls)


def test_status_many_siblings_without_probe_are_probed_once(monkeypatch):
    # The tie-break snapshot is handed to the attached worker: each sibling
    # pays one probe attempt and nothing else.
    a = FakeContainer("c-a", "a", "u-a", "/workspaces/ws-a")
    b = FakeContainer("c-b", "b", "u-b", "/workspaces/ws-a")
    insp = _inspector([a, b], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 0
    assert a.exec_calls == [["dvw-probe"]] and b.exec_calls == [["dvw-probe"]]


def test_inspect_partial_report_is_partial(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a",
                      probe={**GOOD, "partial": True})
    insp = _inspector([c], monkeypatch)
    assert insp.inspect("ws-a").probe == "partial"


def test_inspect_mem_falls_back_to_cgroup(monkeypatch):
    # No docker stats from the fake client, so the probe's cgroup numbers fill in.
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.mem_bytes == 1234 and info.mem_limit == 8589934592


def _probe_execs(c):
    return sum(1 for cmd in c.exec_calls if cmd == ["dvw-probe"])


def _shared_inspector(containers, monkeypatch, ttl=5.0):
    import app.docker_inspect as di
    monkeypatch.setattr(di.docker, "DockerClient", lambda base_url=None, timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="unix:/nonexistent", resolve_cache_ttl=0,
                                    probe_snapshot_ttl=ttl))


def test_status_request_and_activity_sampler_share_one_probe_per_window(monkeypatch):
    c = _probe_container()
    insp = _shared_inspector([c], monkeypatch)
    insp.status_many(["ws-a"])
    insp.activity_many(["ws-a"])
    insp.windows_many()
    insp.fleet_members()
    assert _probe_execs(c) == 1


def test_snapshot_ttl_zero_probes_every_call(monkeypatch):
    c = _probe_container()
    insp = _shared_inspector([c], monkeypatch, ttl=0)
    insp.status_many(["ws-a"])
    insp.activity_many(["ws-a"])
    assert _probe_execs(c) == 2


def test_snapshot_expires_after_its_window(monkeypatch):
    import app.docker_inspect as di
    clock = [1000.0]
    monkeypatch.setattr(di.time, "monotonic", lambda: clock[0])
    c = _probe_container()
    insp = _shared_inspector([c], monkeypatch)
    insp.windows_many()
    clock[0] += 4.9
    insp.windows_many()
    assert _probe_execs(c) == 1
    clock[0] += 0.2
    insp.windows_many()
    assert _probe_execs(c) == 2


def test_restarted_container_is_probed_again(monkeypatch):
    c = _probe_container()
    insp = _shared_inspector([c], monkeypatch)
    insp.windows_many()
    c.attrs["State"]["StartedAt"] = "2026-09-26T00:00:00Z"
    insp.windows_many()
    assert _probe_execs(c) == 2


def test_concurrent_callers_never_run_overlapping_probes(monkeypatch):
    # Overlapping probes see each other in /proc (the tmux false-zero).
    import threading
    import time as real_time
    import app.docker_inspect as di
    running, overlaps, calls = [0], [0], [0]
    lock = threading.Lock()
    real = di.run_probe

    def slow_probe(container):
        with lock:
            running[0] += 1
            calls[0] += 1
            overlaps[0] = max(overlaps[0], running[0])
        real_time.sleep(0.1)
        try:
            return real(container)
        finally:
            with lock:
                running[0] -= 1

    monkeypatch.setattr(di, "run_probe", slow_probe)
    c = _probe_container()
    insp = _shared_inspector([c], monkeypatch)
    threads = [threading.Thread(target=insp._snapshot, args=(c,)) for _ in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert overlaps[0] == 1 and calls[0] == 1
