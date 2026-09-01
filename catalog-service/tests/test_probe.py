"""ProbeReport parsing and run_probe: the probe's output is untrusted input."""

from __future__ import annotations

import json

import pytest

from app.probe import MAX_OUTPUT, ProbeMissing, ProbeReport, run_probe
from tests.test_resolver import FakeExecResult

GOOD = {
    "schema": 1, "ts": 1756800000, "partial": False,
    "tmux": {"sessions": [{"name": "work", "attached": 1, "activity": 1756799990}],
             "windows": [{"id": "@7", "name": "claude", "active": True,
                          "activity": 1756799990, "waiting_since": None, "command": "node"},
                         {"id": "@8", "name": "shell", "active": False,
                          "activity": 1756790000, "waiting_since": 1756795000, "command": "bash"}]},
    "agents": [{"cli": "claude", "pid": 4242, "started": 1756790000, "cwd": "/workspaces/foo"}],
    "git": {"root": "/workspaces/foo", "branch": "feat/x", "head": "abc1234",
            "dirty": True, "ahead": 2, "behind": 0},
    "cgroup": {"mem_current": 1234, "mem_max": 8589934592, "cpu_usec": 1, "nr_procs": 42},
}


class ProbeContainer:
    def __init__(self, exit_code=0, stdout=b"", cmds=None):
        self.id = "c1"
        self.status = "running"
        self._exit = exit_code
        self._stdout = stdout
        self.cmds = cmds if cmds is not None else []

    def exec_run(self, cmd, demux=False):
        self.cmds.append(cmd)
        return FakeExecResult(self._exit, self._stdout)


def test_parse_good_report_and_helpers():
    r = ProbeReport.model_validate(GOOD)
    assert r.schema_ == 1
    assert r.work_activity() == 1756799990
    assert r.work_attached() == 1
    wins = r.work_windows()
    assert [w.window_id for w in wins] == ["@7", "@8"]
    assert wins[1].waiting_since == 1756795000 and wins[1].command == "bash"
    assert r.agents[0].cli == "claude"
    assert r.git.branch == "feat/x"


def test_null_sections_are_fine():
    r = ProbeReport.model_validate({"schema": 1, "ts": 1, "tmux": None, "agents": None,
                                    "git": None, "cgroup": None})
    assert r.work_activity() == -1 and r.work_attached() == 0 and r.work_windows() == []


def test_unknown_keys_ignored_and_wrong_types_rejected():
    ProbeReport.model_validate({**GOOD, "surprise": {"x": 1}})
    with pytest.raises(Exception):
        ProbeReport.model_validate({**GOOD, "agents": [{"cli": "claude", "pid": "not-int"}]})


def test_list_and_string_caps():
    too_many = {**GOOD, "agents": [{"cli": "claude", "pid": i} for i in range(65)]}
    with pytest.raises(Exception):
        ProbeReport.model_validate(too_many)
    long_name = {**GOOD, "git": {**GOOD["git"], "branch": "b" * 513}}
    with pytest.raises(Exception):
        ProbeReport.model_validate(long_name)


def test_run_probe_execs_dvw_probe_and_parses():
    c = ProbeContainer(0, json.dumps(GOOD).encode())
    r = run_probe(c)
    assert r is not None and r.work_attached() == 1
    assert c.cmds == [["dvw-probe"]]


@pytest.mark.parametrize("code", [126, 127])
def test_run_probe_missing_raises(code):
    with pytest.raises(ProbeMissing):
        run_probe(ProbeContainer(code, b"exec: dvw-probe: not found"))


def test_run_probe_other_failures_return_none():
    assert run_probe(ProbeContainer(1, b"boom")) is None
    assert run_probe(ProbeContainer(0, b"not json")) is None
    assert run_probe(ProbeContainer(0, b"x" * (MAX_OUTPUT + 1))) is None
    assert run_probe(ProbeContainer(0, json.dumps({"schema": 2, "ts": 1}).encode())) is None


def test_run_probe_exec_exception_returns_none():
    class Boom(ProbeContainer):
        def exec_run(self, cmd, demux=False):
            raise RuntimeError("docker down")
    assert run_probe(Boom()) is None


def test_validation_failure_log_never_echoes_probe_content(caplog):
    marker = "TOTALLY-SECRET-MARKER-98765"
    bad = {**GOOD, "agents": [{"cli": "claude", "pid": marker}]}
    c = ProbeContainer(0, json.dumps(bad).encode())
    with caplog.at_level("WARNING"):
        assert run_probe(c) is None
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert marker not in text
    assert c.id in text


@pytest.mark.parametrize("field_path,bad_value", [
    (("tmux", "sessions", 0, "attached"), -1),
    (("tmux", "sessions", 0, "activity"), -1),
    (("tmux", "windows", 0, "activity"), -1),
    (("tmux", "windows", 0, "waiting_since"), -1),
    (("agents", 0, "pid"), -1),
    (("agents", 0, "started"), -1),
    (("git", "ahead"), -1),
    (("git", "behind"), -1),
    (("cgroup", "mem_current"), -1),
    (("cgroup", "mem_max"), -1),
    (("cgroup", "cpu_usec"), -1),
    (("cgroup", "nr_procs"), -1),
    (("ts",), -1),
])
def test_negative_values_rejected(field_path, bad_value):
    import copy
    data = copy.deepcopy(GOOD)
    node = data
    for key in field_path[:-1]:
        node = node[key]
    node[field_path[-1]] = bad_value
    with pytest.raises(Exception):
        ProbeReport.model_validate(data)
