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

    monkeypatch.setattr(di.docker, "DockerClient", lambda base_url=None, timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="unix:/nonexistent", resolve_cache_ttl=0))


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


def test_windows_many_uses_resolvers_canonical_sibling(monkeypatch):
    canonical = FakeContainer(
        "c-real", "real", "u-real", "/workspaces/ws-a",
        tmux_work=200,
        tmux_windows="@1\treal\t1\t200\t1754899000\tclaude\t1\n",
    )
    other = FakeContainer(
        "c-other", "other", "u-other", "/workspaces/ws-a",
        tmux_work=100,
        tmux_windows="@9\twrong\t1\t100\t1754899999\tbash\t1\n",
    )
    # Put the noncanonical sibling last to reproduce the response-order bug
    # that used to overwrite the canonical snapshot in the TUI client.
    insp = _inspector([canonical, other], monkeypatch)

    assert insp.resolve("ws-a").container_id == "c-real"
    (snapshot,) = insp.windows_many()
    assert snapshot.container_id == "c-real"
    assert [w.window_id for w in snapshot.windows] == ["@1"]
    assert [w.container_id for w in insp.waiting_windows()] == ["c-real"]


def test_windows_many_single_candidate_costs_one_exec_per_container(monkeypatch):
    # The snapshot itself is the only exec allowed on the common path: the
    # canonical-container decision must not add a probe when a workspace has
    # exactly one running candidate (2N serial execs was a real latency
    # regression against the TUI's request timeout).
    from tests.test_probe import GOOD

    calls: list[list[str]] = []
    containers = []
    for i in range(3):
        c = FakeContainer(
            f"c{i}", f"n{i}", f"u{i}", f"/workspaces/ws-{i}", probe=GOOD,
        )
        original = c.exec_run

        def counted(cmd, demux=False, *, run=original):
            calls.append(list(cmd))
            return run(cmd, demux=demux)

        c.exec_run = counted
        containers.append(c)
    insp = _inspector(containers, monkeypatch)

    snapshots = insp.windows_many()

    assert len(snapshots) == 3
    assert calls == [["dvw-probe"]] * 3


def test_windows_many_probe_missing_never_snapshots_a_container_twice(monkeypatch):
    # Same invariant for a container without dvw-probe: the one failed probe
    # attempt is memoized for the request, no second exec of any kind.
    containers = [
        FakeContainer(f"c{i}", f"n{i}", f"u{i}", f"/workspaces/ws-{i}")
        for i in range(3)
    ]
    insp = _inspector(containers, monkeypatch)

    assert len(insp.windows_many()) == 3
    for c in containers:
        assert c.exec_calls == [["dvw-probe"]]


def test_windows_many_omits_ambiguous_siblings_without_tmux(monkeypatch):
    a = FakeContainer(
        "c-a", "a", "u-a", "/workspaces/ws-a", tmux_work=None,
        tmux_windows="@1\ta\t1\t10\t1754899000\tclaude\t1\n",
    )
    b = FakeContainer(
        "c-b", "b", "u-b", "/workspaces/ws-a", tmux_work=None,
        tmux_windows="@9\tb\t1\t20\t1754899999\tclaude\t1\n",
    )
    insp = _inspector([a, b], monkeypatch)

    assert insp.resolve("ws-a").ambiguous is True
    assert insp.windows_many() == []
    assert insp.waiting_windows() == []


def test_waiting_windows_projects_flagged_windows_newest_first(monkeypatch):
    # ws-a: one waiting window (older) + one non-waiting window.
    a = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_windows=(
        "@1\tfeat-a\t1\t1754890000\t1754891000\tclaude\t1\n"
        "@2\tidle-a\t0\t1754880000\t\tbash\t1\n"
    ))
    # ws-b: one waiting window (newer, different epoch) + one non-waiting.
    b = FakeContainer("c2", "n2", "u2", "/workspaces/ws-b", tmux_windows=(
        "@3\tbuild-b\t0\t1754870000\t\tbash\t1\n"
        "@4\tfeat-b\t1\t1754860000\t1754899000\tclaude\t1\n"
    ))
    insp = _inspector([a, b], monkeypatch)
    result = insp.waiting_windows()

    assert [w.window_id for w in result] == ["@4", "@1"]
    assert [w.waiting_since for w in result] == [1754899000, 1754891000]

    w_b, w_a = result
    assert w_b.workspace_id == "ws-b" and w_b.container_id == "c2"
    assert w_b.window_id == "@4" and w_b.window_name == "feat-b"
    assert w_a.workspace_id == "ws-a" and w_a.container_id == "c1"
    assert w_a.window_id == "@1" and w_a.window_name == "feat-a"


def test_waiting_windows_empty_when_nothing_flagged(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_windows=(
        "@1\twork\t1\t1754900000\t\tclaude\t1\n"
    ))
    insp = _inspector([c], monkeypatch)
    assert insp.waiting_windows() == []
