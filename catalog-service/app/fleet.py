"""Publish the shared-config consumer proof for the aicoding updater.

Every running devpod container that bind-mounts one of the shared agent config
roots is a consumer of it. The proof lists each consumer's verified component
versions so the updater can decide whether a shared config change is safe.
Contract: aiCodingBaseSetup docs/automatic-updates.md, "Shared consumer evidence".
"""

from __future__ import annotations

import asyncio
import contextlib
import datetime
import json
import logging
import os
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from starlette.concurrency import run_in_threadpool

from .probe import CAPABILITY_NAMES, ProbeReport

log = logging.getLogger(__name__)

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


def write_proof(path: Path, proof: dict) -> bool:
    try:
        fd, tmp = tempfile.mkstemp(prefix=".consumer-versions.", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(proof, fh, separators=(",", ":"))
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise
    except OSError as e:
        log.warning("fleet proof write failed: %s", type(e).__name__)
        return False
    return True


def remove_proof(path: Path) -> None:
    with contextlib.suppress(FileNotFoundError):
        path.unlink()


class FleetPublisher:
    """Full probe pass every `interval`; between passes, a cheap id watcher.

    A container id the last pass did not cover deletes the proof at once, so
    no updater can authorize a shared write against an inventory that does
    not include the new container, and then triggers a full pass.
    """

    def __init__(self, path: Path, *, ttl: int, interval: float, watch_interval: float, clock=time.time):
        self._path = path
        self._ttl = ttl
        self._interval = interval
        self._watch = watch_interval
        self._clock = clock

    async def publish_once(self, inspector) -> set[str]:
        members = await run_in_threadpool(inspector.fleet_members)
        proof = build_proof(members, now=self._clock(), ttl=self._ttl)
        if not write_proof(self._path, proof):
            # write_proof already logged the reason. A stale proof must not
            # be reported as covering these ids: fail the pass so run()
            # removes whatever proof is on disk and retries.
            raise RuntimeError("fleet proof write failed")
        return {m.container_id for m in members}

    def _safe_remove(self) -> None:
        try:
            remove_proof(self._path)
        except OSError as e:
            log.warning("fleet proof remove failed: %s", type(e).__name__)

    async def run(self, inspector) -> None:
        # A proof left by a previous catalog process must not outlive a restart.
        self._safe_remove()
        while True:
            try:
                covered = await self.publish_once(inspector)
            except Exception as e:
                log.warning("fleet proof pass failed: %s", type(e).__name__)
                covered = None
                # A failed pass must not leave a stale proof valid up to its TTL.
                self._safe_remove()
            deadline = time.monotonic() + self._interval
            while time.monotonic() < deadline:
                await asyncio.sleep(self._watch)
                if covered is None:
                    continue
                try:
                    ids = await run_in_threadpool(inspector.running_container_ids)
                except Exception as e:
                    log.warning("fleet watcher failed: %s", type(e).__name__)
                    continue
                if ids - covered:
                    self._safe_remove()
                    break
