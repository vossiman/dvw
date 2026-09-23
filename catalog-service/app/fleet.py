"""Publish the shared-config consumer proof for the aicoding updater.

Every running devpod container that bind-mounts one of the shared agent config
roots is a consumer of it. The proof lists each consumer's verified component
versions so the updater can decide whether a shared config change is safe.
Contract: aiCodingBaseSetup docs/automatic-updates.md, "Shared consumer evidence".
"""

from __future__ import annotations

import datetime
from dataclasses import dataclass, field

from .probe import CAPABILITY_NAMES, ProbeReport

SHARED_ROOTS = ("/home/codespace/.claude", "/home/codespace/.codex", "/home/codespace/.cursor")
REPORT_WINDOW = (-5, 90)  # seconds a probe timestamp may lead or trail the host clock


@dataclass
class FleetMember:
    container_id: str
    started_at: float | None
    mounts: dict[str, str] = field(default_factory=dict)
    report: ProbeReport | None = None


def parse_docker_time(value: str | None) -> float | None:
    if not value or value.startswith("0001-"):
        return None
    try:
        head, _, frac = value.rstrip("Z").partition(".")
        stamp = datetime.datetime.fromisoformat(head).replace(tzinfo=datetime.timezone.utc)
        return stamp.timestamp() + (float("0." + frac[:6]) if frac else 0.0)
    except ValueError:
        return None


def _components(report: ProbeReport | None) -> dict[str, dict]:
    if report is None or report.capabilities is None:
        return {}
    out = {}
    for name in CAPABILITY_NAMES:
        cap = report.capabilities.get(name)
        if cap is not None and cap.config_compatible:
            out[name] = {"version": cap.version, "config_compatible": True}
    return out


def _verified(member: FleetMember, now: float) -> bool:
    r = member.report
    if r is None or r.partial:
        return False
    lo, hi = REPORT_WINDOW
    if not lo <= now - r.ts <= hi:
        return False
    return len(_components(r)) == len(CAPABILITY_NAMES)


def build_proof(members: list[FleetMember], *, now: float, ttl: int = 300) -> dict:
    starts = [m.started_at for m in members]
    starts_known = all(s is not None for s in starts)
    newest = int(max(starts)) if members and starts_known else 0
    roots = []
    for root in SHARED_ROOTS:
        users = [m for m in members if root in m.mounts]
        if not users:
            continue
        complete = (starts_known
                    and len({m.mounts[root] for m in users}) == 1
                    and all(_verified(m, now) for m in users))
        roots.append({
            "shared_root": root,
            "inventory_complete": complete,
            "expires_at": int(now) + ttl,
            "consumers": [{"id": m.container_id, "components": _components(m.report)} for m in users],
        })
    return {"schema": 1, "generated_at": int(now), "newest_container_started_at": newest, "roots": roots}
