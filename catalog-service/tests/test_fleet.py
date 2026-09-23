from __future__ import annotations

from app.fleet import SHARED_ROOTS, FleetMember, build_proof, parse_docker_time
from app.probe import CAPABILITY_NAMES, ProbeReport
from tests.test_probe import GOOD

NOW = 1_790_000_000.0
CAPS = {
    n: {
        "version": "a71a8bdcd12e39fcb74be3ecc0e45f757118f0e3" if n == "mcp-kanban" else "1.2.3",
        "config_compatible": True,
    }
    for n in CAPABILITY_NAMES
}
MOUNTS = {r: "/home/vossi/devpod/" + r.rsplit(".", 1)[1] for r in SHARED_ROOTS}


def _report(**over):
    return ProbeReport.model_validate({**GOOD, "ts": int(NOW), "capabilities": CAPS, **over})


def _member(cid, report="good", mounts=None, started=NOW - 600):
    rep = _report() if report == "good" else report
    return FleetMember(cid, started, dict(MOUNTS if mounts is None else mounts), rep)


def _root(proof, root):
    (entry,) = [r for r in proof["roots"] if r["shared_root"] == root]
    return entry


def test_all_good_is_complete_and_fresh():
    p = build_proof([_member("a"), _member("b")], now=NOW)
    assert p["schema"] == 1 and p["generated_at"] == int(NOW)
    assert p["newest_container_started_at"] == int(NOW - 600)
    for root in SHARED_ROOTS:
        r = _root(p, root)
        assert r["inventory_complete"] is True and r["expires_at"] == int(NOW) + 300
        assert [c["id"] for c in r["consumers"]] == ["a", "b"]
        assert r["consumers"][0]["components"]["mcp-playwright"] == CAPS["mcp-playwright"]


def test_failed_probe_makes_its_roots_incomplete():
    p = build_proof([_member("a"), _member("b", report=None)], now=NOW)
    assert all(r["inventory_complete"] is False for r in p["roots"])


def test_partial_or_stale_report_is_incomplete():
    assert all(not r["inventory_complete"] for r in
               build_proof([_member("a", report=_report(partial=True))], now=NOW)["roots"])
    assert all(not r["inventory_complete"] for r in
               build_proof([_member("a", report=_report(ts=int(NOW) - 600))], now=NOW)["roots"])


def test_missing_capabilities_or_one_component_is_incomplete():
    old = ProbeReport.model_validate({**GOOD, "ts": int(NOW)})
    assert all(not r["inventory_complete"] for r in build_proof([_member("a", report=old)], now=NOW)["roots"])
    one_null = _report(capabilities={**CAPS, "mcp-context7": None})
    p = build_proof([_member("a"), _member("b", report=one_null)], now=NOW)
    assert all(not r["inventory_complete"] for r in p["roots"])
    assert "mcp-context7" not in _root(p, SHARED_ROOTS[0])["consumers"][1]["components"]


def test_duplicate_siblings_both_counted():
    p = build_proof([_member("a"), _member("a2")], now=NOW)
    assert len(_root(p, SHARED_ROOTS[0])["consumers"]) == 2


def test_root_only_covers_containers_that_mount_it():
    only_claude = {SHARED_ROOTS[0]: MOUNTS[SHARED_ROOTS[0]]}
    p = build_proof([_member("a"), _member("b", mounts=only_claude)], now=NOW)
    assert [c["id"] for c in _root(p, SHARED_ROOTS[1])["consumers"]] == ["a"]
    assert [c["id"] for c in _root(p, SHARED_ROOTS[0])["consumers"]] == ["a", "b"]


def test_different_host_sources_for_one_root_is_incomplete_not_duplicated():
    other = {**MOUNTS, SHARED_ROOTS[0]: "/somewhere/else"}
    p = build_proof([_member("a"), _member("b", mounts=other)], now=NOW)
    assert len([r for r in p["roots"] if r["shared_root"] == SHARED_ROOTS[0]]) == 1
    assert _root(p, SHARED_ROOTS[0])["inventory_complete"] is False
    assert _root(p, SHARED_ROOTS[1])["inventory_complete"] is True


def test_unknown_start_time_makes_everything_incomplete():
    p = build_proof([_member("a", started=None)], now=NOW)
    assert all(not r["inventory_complete"] for r in p["roots"])


def test_no_running_containers_gives_no_roots():
    assert build_proof([], now=NOW)["roots"] == []


def test_parse_docker_time_handles_nanoseconds_and_garbage():
    assert parse_docker_time("2026-09-23T12:00:00.123456789Z") == parse_docker_time("2026-09-23T12:00:00.123456Z")
    assert parse_docker_time("0001-01-01T00:00:00Z") is None
    assert parse_docker_time(None) is None and parse_docker_time("nope") is None


import json
import os

from app.config import Settings
from app.fleet import remove_proof, write_proof
from tests.test_resolver import FakeContainer, _inspector


def _running(cid, started="2026-09-23T10:00:00.5Z", probe=None, extra_mounts=MOUNTS):
    c = FakeContainer(cid, f"n-{cid}", f"u-{cid}", "/workspaces/ws-a",
                      probe=probe or {**GOOD, "ts": int(NOW), "capabilities": CAPS})
    c.attrs["State"]["StartedAt"] = started
    c.attrs["Mounts"] += [{"Destination": d, "Source": s, "Type": "bind"} for d, s in extra_mounts.items()]
    return c


def test_fleet_members_covers_duplicates_and_skips_stopped(monkeypatch):
    stopped = _running("s")
    stopped.status = "exited"
    insp = _inspector([_running("a"), _running("a2"), stopped], monkeypatch)
    members = insp.fleet_members()
    assert [m.container_id for m in members] == ["a", "a2"]
    assert members[0].mounts["/home/codespace/.claude"] == MOUNTS["/home/codespace/.claude"]
    assert members[0].started_at == parse_docker_time("2026-09-23T10:00:00.5Z")
    assert members[0].report.capabilities["claude"].version == "1.2.3"


def test_fleet_members_probe_missing_is_a_member_without_report(monkeypatch):
    c = _running("a")
    c._probe, c._probe_exit = None, 127
    (m,) = _inspector([c], monkeypatch).fleet_members()
    assert m.report is None


def test_fleet_members_passes_through_full_container_id(monkeypatch):
    full_id = "f" * 64
    c = _running(full_id)
    (m,) = _inspector([c], monkeypatch).fleet_members()
    assert m.container_id == full_id


def test_running_container_ids(monkeypatch):
    stopped = _running("s")
    stopped.status = "exited"
    assert _inspector([_running("a"), stopped], monkeypatch).running_container_ids() == {"a"}


def test_write_proof_is_atomic_and_readable(tmp_path):
    target = tmp_path / "fleet" / "consumer-versions.json"
    target.parent.mkdir()
    assert write_proof(target, {"schema": 1, "roots": []}) is True
    assert json.loads(target.read_text()) == {"schema": 1, "roots": []}
    assert oct(target.stat().st_mode & 0o777) == "0o644"
    assert [p.name for p in target.parent.iterdir()] == ["consumer-versions.json"]


def test_write_proof_missing_dir_returns_false(tmp_path, caplog):
    assert write_proof(tmp_path / "absent" / "x.json", {"schema": 1}) is False
    assert "fleet proof write failed" in caplog.text


def test_remove_proof_tolerates_absence(tmp_path):
    remove_proof(tmp_path / "x.json")
    (tmp_path / "x.json").write_text("{}")
    remove_proof(tmp_path / "x.json")
    assert not (tmp_path / "x.json").exists()


def test_fleet_proof_path_setting():
    assert Settings(fleet_proof_path="").fleet_proof_file is None
    assert str(Settings(fleet_proof_path="~/p.json").fleet_proof_file) == os.path.expanduser("~/p.json")


import asyncio
import threading
import time
from contextlib import suppress
from pathlib import Path

from app.fleet import FleetPublisher


class StubInspector:
    def __init__(self, members, ids_sequence):
        self.members = members
        self.ids_sequence = list(ids_sequence)
        self.member_calls = 0

    def fleet_members(self):
        self.member_calls += 1
        return self.members

    def running_container_ids(self):
        return self.ids_sequence.pop(0) if len(self.ids_sequence) > 1 else self.ids_sequence[0]


async def _cancel(task):
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task


async def _poll(condition, attempts=200, step=0.01):
    for _ in range(attempts):
        await asyncio.sleep(step)
        if condition():
            break


async def test_publish_once_writes_proof(tmp_path):
    path = tmp_path / "p.json"
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    ids = await pub.publish_once(StubInspector([_member("a")], [{"a"}]))
    assert ids == {"a"}
    assert json.loads(path.read_text())["roots"][0]["consumers"][0]["id"] == "a"


async def test_new_container_deletes_proof_and_triggers_a_pass(tmp_path):
    path = tmp_path / "p.json"
    seen = []

    class Recording(StubInspector):
        def fleet_members(self):
            seen.append(path.exists())
            return super().fleet_members()

    stub = Recording([_member("a")], [{"a"}, {"a", "b"}])
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: stub.member_calls >= 2)
    await _cancel(task)
    assert stub.member_calls >= 2
    # The second fleet_members call (triggered by the new container id) ran
    # after the stale proof was deleted. "b" is never enumerated, so every
    # later pass also refuses to write.
    assert seen[:2] == [False, False] and not any(seen)
    assert not path.exists()


async def test_watcher_removes_file_before_reprobing(tmp_path):
    path = tmp_path / "p.json"
    seen = []

    class Slow(StubInspector):
        def fleet_members(self):
            seen.append(path.exists())
            return super().fleet_members()

    stub = Slow([_member("a")], [{"a"}, {"a", "b"}])
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: len(seen) >= 2)
    await _cancel(task)
    assert seen[:2] == [False, False]


async def test_enumeration_failure_keeps_running(tmp_path, caplog):
    class Broken(StubInspector):
        def fleet_members(self):
            self.member_calls += 1
            raise RuntimeError("docker down")

    stub = Broken([], [set()])
    pub = FleetPublisher(tmp_path / "p.json", ttl=300, interval=0.01, watch_interval=0.005, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await asyncio.sleep(0.1)
    await _cancel(task)
    assert stub.member_calls >= 2
    assert "fleet proof pass failed" in caplog.text


async def test_run_removes_a_preexisting_proof_on_start(tmp_path):
    path = tmp_path / "p.json"
    path.write_text('{"stale": true}')
    stub = StubInspector([_member("a")], [{"a"}])
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: stub.member_calls >= 1)
    await _cancel(task)
    # The restart-time removal ran before the first pass wrote the fresh proof.
    assert json.loads(path.read_text())["roots"][0]["consumers"][0]["id"] == "a"


async def test_enumeration_failure_removes_a_stale_proof(tmp_path):
    path = tmp_path / "p.json"

    class Broken(StubInspector):
        def fleet_members(self):
            self.member_calls += 1
            if self.member_calls == 1:
                return super().fleet_members()
            raise RuntimeError("docker down")

    stub = Broken([_member("a")], [{"a"}])
    pub = FleetPublisher(path, ttl=300, interval=0.02, watch_interval=0.005, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: stub.member_calls >= 1)
    assert path.exists()
    await _poll(lambda: stub.member_calls >= 2)
    await _poll(lambda: not path.exists())
    await _cancel(task)
    assert not path.exists()


async def test_write_failure_removes_a_stale_proof(tmp_path, monkeypatch):
    path = tmp_path / "p.json"
    from app import fleet as fleet_module

    calls = {"n": 0}
    real_write_proof = fleet_module.write_proof

    def flaky_write_proof(target_path, proof):
        calls["n"] += 1
        if calls["n"] == 1:
            return real_write_proof(target_path, proof)
        return False

    monkeypatch.setattr(fleet_module, "write_proof", flaky_write_proof)
    stub = StubInspector([_member("a")], [{"a"}])
    pub = FleetPublisher(path, ttl=300, interval=0.02, watch_interval=0.005, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: calls["n"] >= 1)
    assert path.exists()
    await _poll(lambda: calls["n"] >= 2)
    await _poll(lambda: not path.exists())
    await _cancel(task)
    assert not path.exists()


class Gated(StubInspector):
    """fleet_members blocks until the test releases it, like a slow probe pass."""

    def __init__(self, members, ids_sequence):
        super().__init__(members, ids_sequence)
        self.release = threading.Event()

    def fleet_members(self):
        self.member_calls += 1
        self.release.wait(5)
        return self.members


async def test_new_id_after_enumeration_blocks_the_write_and_removes_the_old_proof(tmp_path):
    path = tmp_path / "p.json"
    path.write_text('{"old": true}')
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    # "b" started after the enumeration listed containers: not a member, but running.
    covered = await pub.publish_once(StubInspector([_member("a")], [{"a", "b"}]), {"a"})
    assert covered is None
    assert not path.exists()


async def test_watcher_keeps_running_while_a_pass_probes(tmp_path):
    path = tmp_path / "p.json"
    path.write_text('{"old": true}')
    stub = Gated([_member("a")], [{"a", "b"}])
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    task = asyncio.create_task(pub.publish_once(stub, {"a"}))
    await _poll(lambda: not path.exists())
    # The old proof is gone while fleet_members is still probing.
    assert stub.member_calls == 1 and not stub.release.is_set()
    assert not path.exists()
    stub.release.set()
    assert await task is None
    assert not path.exists()


async def test_container_started_during_a_pass_is_retried_without_a_full_interval(tmp_path):
    path = tmp_path / "p.json"

    class Late(StubInspector):
        def fleet_members(self):
            self.member_calls += 1
            if self.member_calls == 1:
                return [_member("a")]
            return [_member("a"), _member("b")]

    stub = Late([], [{"a", "b"}])
    pub = FleetPublisher(path, ttl=300, interval=30, watch_interval=0.01, clock=lambda: NOW)
    task = asyncio.create_task(pub.run(stub))
    await _poll(lambda: path.exists())
    await _cancel(task)
    assert stub.member_calls == 2
    assert [c["id"] for c in json.loads(path.read_text())["roots"][0]["consumers"]] == ["a", "b"]


def test_mount_target_mismatch_marks_the_root_incomplete():
    claude = SHARED_ROOTS[0]
    relocated = {**MOUNTS}
    del relocated[claude]
    relocated["/home/vscode/.claude"] = MOUNTS[claude]
    p = build_proof([_member("a"), _member("b", mounts=relocated)], now=NOW)
    assert _root(p, claude)["inventory_complete"] is False
    assert [c["id"] for c in _root(p, claude)["consumers"]] == ["a"]
    assert _root(p, SHARED_ROOTS[1])["inventory_complete"] is True


def test_parent_directory_of_a_root_source_marks_it_incomplete():
    parent = {**MOUNTS, "/mnt/devpod": "/home/vossi/devpod/"}
    p = build_proof([_member("a"), _member("b", mounts=parent)], now=NOW)
    assert all(r["inventory_complete"] is False for r in p["roots"])


def test_unrelated_sibling_source_does_not_mark_incomplete():
    near = {**MOUNTS, "/home/codespace/.aicodingsetup": "/home/vossi/devpod/claude-other"}
    p = build_proof([_member("a", mounts=near)], now=NOW)
    assert all(r["inventory_complete"] is True for r in p["roots"])


def test_lifespan_removes_the_proof_on_shutdown(monkeypatch, settings, tmp_path):
    from fastapi.testclient import TestClient

    import app.main as main

    path = tmp_path / "fleet" / "consumer-versions.json"
    path.parent.mkdir()
    cfg = settings.model_copy(update={"fleet_proof_path": str(path), "fleet_watch_interval": 0.01})
    stub = StubInspector([_member("a")], [{"a"}])
    monkeypatch.setattr(main, "get_settings", lambda: cfg)
    monkeypatch.setattr(main, "DockerInspector", lambda _: stub)
    with TestClient(main.create_app()):
        for _ in range(200):
            if path.exists():
                break
            time.sleep(0.01)
        assert path.exists()
    assert not path.exists()


CONTRACT = Path(__file__).parent / "fixtures" / "fleet-proof-contract.json"
CONTRACT_IDS = ("7e3c1a9b5d2f4e6a8c0b1d3f5a7c9e2b4d6f8a0c1e3b5d7f9a2c4e6b8d0f1a3c",
                "0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c")


def contract_proof() -> dict:
    return build_proof([_member(cid) for cid in CONTRACT_IDS], now=NOW)


def test_cross_repo_contract_fixture_matches_build_proof():
    """aiCodingBaseSetup keeps a copy of this file (tests/bats/fixtures/
    fleet-proof-contract.json) and checks its gate opens on it. Regenerate
    with: python -c 'from tests.test_fleet import write_contract; write_contract()'
    and copy it over there too.
    """
    proof = contract_proof()
    assert all(r["inventory_complete"] for r in proof["roots"])
    assert json.loads(CONTRACT.read_text()) == proof


def write_contract() -> None:
    CONTRACT.write_text(json.dumps(contract_proof(), indent=2) + "\n")
