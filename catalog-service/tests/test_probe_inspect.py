"""docker_inspect uses dvw-probe first and falls back to tmux execs only
when the probe is missing (exit 126/127). One exec per container per call."""

from __future__ import annotations

from app.config import Settings
from app.docker_inspect import DockerInspector
from tests.test_probe import GOOD
from tests.test_resolver import FakeClient, FakeContainer


def _inspector(containers, monkeypatch):
    import app.docker_inspect as di
    monkeypatch.setattr(di.docker, "from_env", lambda timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="", resolve_cache_ttl=0))


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


def test_probe_missing_falls_back_to_tmux(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=2, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.attached == 2 and ww.windows[0].window_id == "@1"
    assert insp.resolve("ws-a").tmux_work_activity == 100
    assert any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_probe_missing_windows_costs_one_tmux_exec(monkeypatch):
    # The windows exec already carries session_attached, and windows_many
    # never reads activity: one tmux exec, not three.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=2, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    insp.windows_many()
    tmux = [cmd for cmd in c.exec_calls if cmd[0] == "tmux"]
    assert [cmd[1] for cmd in tmux] == ["list-windows"]


def test_probe_missing_detached_session_does_not_fire_the_attached_exec(monkeypatch):
    # session_attached=0 is the normal DETACHED state, not "no answer": the
    # windows exec answered, so the attached exec must not run.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=4, tmux_windows="@1\twork\t1\t5\t\tclaude\t0\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.attached == 0
    tmux = [cmd for cmd in c.exec_calls if cmd[0] == "tmux"]
    assert [cmd[1] for cmd in tmux] == ["list-windows"]


def test_attached_many_on_legacy_container_runs_only_the_attached_exec(monkeypatch):
    # The bulk status fan-out spends its execs inside a 0.25 s budget: a
    # container without dvw-probe must cost exactly the one list-sessions
    # exec it did before the probe existed.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=3, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    assert insp._attached_many([c]) == {"c1": 3}
    tmux = [cmd for cmd in c.exec_calls if cmd[0] == "tmux"]
    assert len(tmux) == 1
    assert tmux[0] == ["tmux", "list-sessions", "-F",
                       "#{session_name} #{session_attached}"]


def test_status_many_legacy_container_costs_one_tmux_exec(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=3, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 3
    tmux = [cmd for cmd in c.exec_calls if cmd[0] == "tmux"]
    assert [cmd[1] for cmd in tmux] == ["list-sessions"]


def test_status_many_legacy_siblings_are_not_probed_twice(monkeypatch):
    # The tie-break snapshot is handed to the attached worker, so the winner
    # pays one probe attempt, one activity exec and one attached exec.
    a = FakeContainer("c-a", "a", "u-a", "/workspaces/ws-a", tmux_work=200,
                      tmux_attached=3)
    b = FakeContainer("c-b", "b", "u-b", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=5)
    insp = _inspector([a, b], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.container_id == "c-a" and st.attached == 3
    assert sum(1 for cmd in a.exec_calls if cmd == ["dvw-probe"]) == 1
    assert [cmd[1] for cmd in a.exec_calls if cmd[0] == "tmux"] == [
        "list-sessions", "list-sessions"]


def test_probe_missing_fallback_argvs_are_proxy_allowed(monkeypatch):
    # Structural pin: the fallback may only send argv lists the docker proxy
    # allows. Byte-identical or the deployed proxy 403s the fallback.
    from proxy.dvw_docker_proxy import _TMUX_ALLOWED

    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100)
    insp = _inspector([c], monkeypatch)
    insp.windows_many()
    insp.status_many(["ws-a"])
    tmux = [cmd for cmd in c.exec_calls if cmd[0] == "tmux"]
    assert tmux, "fallback sent no tmux exec"
    for cmd in tmux:
        assert cmd in [list(a) for a in _TMUX_ALLOWED], cmd


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
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=1)
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.probe == "missing" and info.agents == [] and info.git is None


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
