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
