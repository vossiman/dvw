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
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationError, field_validator

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
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")
MAX_VERSION = 64
# mcp-kanban reports a 40-hex git SHA instead of a semver; every other
# capability reports x.y.z, which real tools suffix (Cursor's is
# "2026.09.18-9a7762b"). SEMVER_RE is deliberately a prefix match, matching
# aicoding's own gate.


class ProbeCapability(BaseModel):
    model_config = ConfigDict(extra="ignore")
    version: Annotated[str, StringConstraints(max_length=MAX_VERSION)]
    config_compatible: Annotated[bool, Field(strict=True)]


def _parse_capability(name: str, raw: object) -> ProbeCapability | None:
    """One capability entry, or None when it is absent or malformed."""
    if not isinstance(raw, dict):
        return None
    version = raw.get("version")
    compatible = raw.get("config_compatible")
    if not isinstance(version, str) or len(version) > MAX_VERSION or not isinstance(compatible, bool):
        return None
    shape_ok = SHA_RE.fullmatch(version) if name == "mcp-kanban" else SEMVER_RE.match(version)
    if not shape_ok:
        return None
    return ProbeCapability(version=version, config_compatible=compatible)


def _parse_capabilities(value: object) -> dict[str, ProbeCapability | None] | None:
    """Lenient on purpose: aicoding updates itself, dvw deploys by hand.

    A probe that reports a component this catalog does not know yet, or one
    entry in a shape it does not accept, must not reject the whole report:
    that would blank activity and status for every container at once. Each
    known entry is validated on its own and becomes None when invalid, which
    keeps it out of the fleet proof (never counted as compatible). Unknown
    keys are dropped. This never raises.
    """
    if not isinstance(value, dict):
        return None
    return {name: _parse_capability(name, value[name]) for name in CAPABILITY_NAMES if name in value}


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
    capabilities: dict[str, ProbeCapability | None] | None = None

    @field_validator("capabilities", mode="before")
    @classmethod
    def _lenient_capabilities(cls, value: object) -> dict[str, ProbeCapability | None] | None:
        return _parse_capabilities(value)

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
