"""dvw-probe output as untrusted input.

The catalog runs `dvw-probe` inside each workspace container (one exec, via
the docker proxy) and gets back one JSON document. The container may be
hostile, so everything here is bounded: output size, list lengths, string
lengths, numeric ranges, and the schema version. Parsing or validation
failures never propagate; callers get None and a warning that names the
container but never echoes probe output (raw field values, including
attacker-controlled strings, must never reach the log).
"""

from __future__ import annotations

import json
import logging
import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationError, model_validator

from .models import WindowInfo

log = logging.getLogger(__name__)

MAX_OUTPUT = 256 * 1024
SCHEMA = 1

Str = Annotated[str, StringConstraints(max_length=512)]
NonNeg = Annotated[int, Field(ge=0)]


class ProbeSession(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: Str
    attached: NonNeg = 0
    # None, not -1: the probe emits -1 for "activity unknown", and a NonNeg
    # field with a -1 default only worked because pydantic skips validating
    # defaults. An explicit -1 on the wire would have dropped the whole
    # report. Null and absent both mean unknown; work_activity() maps that
    # back to -1 for callers.
    activity: int | None = None


class ProbeWindow(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: Str
    name: Str
    active: bool = False
    activity: int | None = None  # -1/null both mean unknown; see ProbeSession
    waiting_since: NonNeg | None = None
    command: Str = ""


class ProbeTmux(BaseModel):
    model_config = ConfigDict(extra="ignore")
    sessions: list[ProbeSession] = Field(default_factory=list, max_length=64)
    windows: list[ProbeWindow] = Field(default_factory=list, max_length=256)


class ProbeAgent(BaseModel):
    model_config = ConfigDict(extra="ignore")
    cli: Str
    pid: NonNeg
    started: NonNeg | None = None
    cwd: Str | None = None


class ProbeGit(BaseModel):
    model_config = ConfigDict(extra="ignore")
    root: Str | None = None
    branch: Str | None = None
    head: Str | None = None
    dirty: bool | None = None
    ahead: NonNeg | None = None
    behind: NonNeg | None = None


class ProbeCgroup(BaseModel):
    model_config = ConfigDict(extra="ignore")
    mem_current: NonNeg | None = None
    mem_max: NonNeg | None = None
    cpu_usec: NonNeg | None = None
    nr_procs: NonNeg | None = None


class ProbeActivity(BaseModel):
    model_config = ConfigDict(extra="ignore")
    tmux_sessions: Annotated[int, Field(ge=0, le=100000, strict=True)] | None = None
    terminals: Annotated[int, Field(ge=0, le=100000, strict=True)] | None = None
    cursor_connections: Annotated[int, Field(ge=0, le=100000, strict=True)] | None = None
    vscode_connections: Annotated[int, Field(ge=0, le=100000, strict=True)] | None = None


CAPABILITY_NAMES = ("claude", "codex", "cursor", "mcp-context7", "mcp-playwright", "mcp-kanban")
CapabilityName = Literal["claude", "codex", "cursor", "mcp-context7", "mcp-playwright", "mcp-kanban"]
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# mcp-kanban reports a 40-hex git SHA instead of a semver; every other
# capability reports x.y.z. Accept either shape at the field level, then
# pin each key to its own shape below.
Version = Annotated[str, StringConstraints(max_length=64, pattern=r"^([0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40})$")]


class ProbeCapability(BaseModel):
    model_config = ConfigDict(extra="ignore")
    version: Version
    config_compatible: Annotated[bool, Field(strict=True)]


class ProbeReport(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)
    schema_: int = Field(alias="schema")
    ts: NonNeg
    partial: bool = False
    tmux: ProbeTmux | None = None
    agents: list[ProbeAgent] | None = Field(default=None, max_length=64)
    activity: ProbeActivity | None = None
    git: ProbeGit | None = None
    cgroup: ProbeCgroup | None = None
    capabilities: dict[CapabilityName, ProbeCapability | None] | None = None

    @model_validator(mode="after")
    def _check_capability_version_shapes(self) -> "ProbeReport":
        if self.capabilities is None:
            return self
        for name, cap in self.capabilities.items():
            if cap is None:
                continue
            if name == "mcp-kanban":
                if not SHA_RE.match(cap.version):
                    raise ValueError("mcp-kanban capability version must be a 40-hex git SHA")
            elif not SEMVER_RE.match(cap.version):
                raise ValueError(f"{name} capability version must be x.y.z")
        return self

    def work_activity(self) -> int:
        if self.tmux is None:
            return -1
        for s in self.tmux.sessions:
            if s.name == "work":
                return -1 if s.activity is None else s.activity
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
                activity=-1 if w.activity is None else w.activity,
                waiting_since=w.waiting_since,
                command=w.command,
            )
            for w in self.tmux.windows
            if w.id.startswith("@")
        ]


class ProbeMissing(Exception):
    """dvw-probe is not installed in this container (exec exit 126/127)."""


def _validation_summary(exc: ValidationError) -> str:
    """Compact, content-free summary of a ValidationError.

    Only `loc` (field path) and `type` (error kind, e.g. "int_parsing") are
    logged. Never touch `err["input"]` or str(exc): both can carry raw probe
    content, including attacker-chosen strings.
    """
    parts = []
    for err in exc.errors():
        loc = ".".join(str(p) for p in err.get("loc", ()))
        parts.append(f"{loc}: {err.get('type', '?')}")
    return "; ".join(parts) or "validation failed"


def run_probe(container) -> ProbeReport | None:
    cid = getattr(container, "id", "?")
    try:
        res = container.exec_run(["dvw-probe"], demux=True)
    except Exception as e:
        log.warning("probe exec failed for %s: %s", cid, type(e).__name__)
        return None
    if res.exit_code in (126, 127):
        raise ProbeMissing(container.id)
    if res.exit_code != 0:
        log.warning("probe exit %s for %s", res.exit_code, cid)
        return None
    stdout = res.output[0] if isinstance(res.output, tuple) else res.output
    if not stdout or len(stdout) > MAX_OUTPUT:
        log.warning("probe output empty or over %d bytes for %s", MAX_OUTPUT, cid)
        return None
    try:
        data = json.loads(stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError as e:
        log.warning("probe output not valid JSON for %s (line %d col %d)", cid, e.lineno, e.colno)
        return None
    try:
        report = ProbeReport.model_validate(data)
    except ValidationError as e:
        log.warning("probe output failed validation for %s: %s", cid, _validation_summary(e))
        return None
    except Exception as e:
        log.warning("probe output rejected for %s: %s", cid, type(e).__name__)
        return None
    if report.schema_ != SCHEMA:
        log.warning("probe schema %s unsupported for %s", report.schema_, cid)
        return None
    return report
