"""dvw-probe output as untrusted input.

The catalog runs `dvw-probe` inside each workspace container (one exec, via
the docker proxy) and gets back one JSON document. The container may be
hostile, so everything here is bounded: output size, list lengths, string
lengths, and the schema version. Parsing failures never propagate; callers
get None and log once.
"""

from __future__ import annotations

import json
import logging
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from .models import WindowInfo

log = logging.getLogger(__name__)

MAX_OUTPUT = 256 * 1024
SCHEMA = 1

Str = Annotated[str, StringConstraints(max_length=512)]


class ProbeSession(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: Str
    attached: int = 0
    activity: int = -1


class ProbeWindow(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: Str
    name: Str
    active: bool = False
    activity: int = -1
    waiting_since: int | None = None
    command: Str = ""


class ProbeTmux(BaseModel):
    model_config = ConfigDict(extra="ignore")
    sessions: list[ProbeSession] = Field(default_factory=list, max_length=64)
    windows: list[ProbeWindow] = Field(default_factory=list, max_length=256)


class ProbeAgent(BaseModel):
    model_config = ConfigDict(extra="ignore")
    cli: Str
    pid: int
    started: int | None = None
    cwd: Str | None = None


class ProbeGit(BaseModel):
    model_config = ConfigDict(extra="ignore")
    root: Str | None = None
    branch: Str | None = None
    head: Str | None = None
    dirty: bool | None = None
    ahead: int | None = None
    behind: int | None = None


class ProbeCgroup(BaseModel):
    model_config = ConfigDict(extra="ignore")
    mem_current: int | None = None
    mem_max: int | None = None
    cpu_usec: int | None = None
    nr_procs: int | None = None


class ProbeReport(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)
    schema_: int = Field(alias="schema")
    ts: int
    partial: bool = False
    tmux: ProbeTmux | None = None
    agents: list[ProbeAgent] | None = Field(default=None, max_length=64)
    git: ProbeGit | None = None
    cgroup: ProbeCgroup | None = None

    def work_activity(self) -> int:
        if self.tmux is None:
            return -1
        for s in self.tmux.sessions:
            if s.name == "work":
                return s.activity
        return -1

    def work_attached(self) -> int:
        if self.tmux is None:
            return 0
        for s in self.tmux.sessions:
            if s.name == "work":
                return max(0, s.attached)
        return 0

    def work_windows(self) -> list[WindowInfo]:
        if self.tmux is None:
            return []
        return [
            WindowInfo(
                window_id=w.id,
                name=w.name,
                active=w.active,
                activity=w.activity,
                waiting_since=w.waiting_since,
                command=w.command,
            )
            for w in self.tmux.windows
            if w.id.startswith("@")
        ]


class ProbeMissing(Exception):
    """dvw-probe is not installed in this container (exec exit 126/127)."""


class ProbeError(Exception):
    pass


def run_probe(container) -> ProbeReport | None:
    try:
        res = container.exec_run(["dvw-probe"], demux=True)
    except Exception as e:
        log.warning("probe exec failed for %s: %s", getattr(container, "id", "?"), e)
        return None
    if res.exit_code in (126, 127):
        raise ProbeMissing(container.id)
    if res.exit_code != 0:
        log.warning("probe exit %s for %s", res.exit_code, container.id)
        return None
    stdout = res.output[0] if isinstance(res.output, tuple) else res.output
    if not stdout or len(stdout) > MAX_OUTPUT:
        log.warning("probe output empty or over %d bytes for %s", MAX_OUTPUT, container.id)
        return None
    try:
        data = json.loads(stdout.decode("utf-8", "replace"))
        report = ProbeReport.model_validate(data)
    except Exception as e:
        log.warning("probe output rejected for %s: %s", container.id, e)
        return None
    if report.schema_ != SCHEMA:
        log.warning("probe schema %s unsupported for %s", report.schema_, container.id)
        return None
    return report
