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
import posixpath
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


def _norm(path: str) -> str:
    return posixpath.normpath(path) if path else path


def _relocated(members: list[FleetMember], root: str, sources: set[str]) -> bool:
    """Does any member bind-mount one of `sources` somewhere other than `root`?

    Such a container uses the shared root through another path (a relocated
    or symlinked home), so its updater never looks up this root entry and
    this pass cannot vouch for it. Mounting a parent directory of a source,
    or a subdirectory of it, exposes the root just the same. Comparison is
    by path component (each candidate is checked with a trailing "/" so a
    sibling with a shared prefix, e.g. "claudeX" against "claude", never
    matches).
    """
    for m in members:
        for dest, src in m.mounts.items():
            if dest == root or not src:
                continue
            src = _norm(src)
            if any(
                s == src
                or s.startswith(src.rstrip("/") + "/")
                or src.startswith(s.rstrip("/") + "/")
                for s in sources
            ):
                return True
    return False


def build_proof(members: list[FleetMember], *, now: float, ttl: int = 300) -> dict:
    # newest_container_started_at comes from the enumerated members only. It
    # is still the newest start of every running container at generated_at:
    # FleetPublisher re-lists running ids after enumeration and refuses to
    # write when any running id is not a member, and generated_at is taken
    # after that recheck. A container that starts later is caught by the
    # watcher, which deletes the proof. The updater-side generated_at check
    # is therefore a consistency check on a complete inventory.
    starts = [m.started_at for m in members]
    starts_known = all(s is not None for s in starts)
    newest = int(max(starts)) if members and starts_known else 0
    roots = []
    for root in SHARED_ROOTS:
        users = [m for m in members if root in m.mounts]
        if not users:
            continue
        sources = {_norm(m.mounts[root]) for m in users if m.mounts[root]}
        complete = (starts_known
                    and all(m.mounts[root] for m in users)
                    and len(sources) == 1
                    and not _relocated(members, root, sources)
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
    """Full probe pass every `interval`; a cheap id watcher at all other times.

    A container id the current proof does not cover deletes the proof at once,
    so no updater can authorize a shared write against an inventory that does
    not include the new container. The watcher keeps polling while a pass is
    probing (a pass takes seconds per container), and a pass that finds a
    running id it did not enumerate writes nothing and retries after one
    watch interval instead of a full interval.
    """

    def __init__(self, path: Path, *, ttl: int, interval: float, watch_interval: float, clock=time.time):
        self._path = path
        self._ttl = ttl
        self._interval = interval
        self._watch = watch_interval
        self._clock = clock

    async def _new_ids(self, inspector, covered: set[str]) -> bool:
        try:
            ids = await run_in_threadpool(inspector.running_container_ids)
        except Exception as e:
            log.warning("fleet watcher failed: %s", type(e).__name__)
            return False
        return bool(ids - covered)

    async def _enumerate(self, inspector, covered: set[str] | None) -> list[FleetMember]:
        """Run fleet_members; meanwhile keep watching the proof on disk."""
        task = asyncio.ensure_future(run_in_threadpool(inspector.fleet_members))
        try:
            while covered is not None:
                done, _ = await asyncio.wait({task}, timeout=self._watch)
                if done:
                    break
                if await self._new_ids(inspector, covered):
                    self._safe_remove()
                    covered = None
            return await task
        finally:
            if not task.done():
                task.cancel()

    async def publish_once(self, inspector, covered: set[str] | None = None) -> set[str] | None:
        """One pass. Returns the ids the new proof covers, or None when a
        container appeared during the pass (proof removed, nothing written).

        `covered` is what the proof currently on disk covers; it is watched
        while the pass runs.
        """
        members = await self._enumerate(inspector, covered)
        ids = {m.container_id for m in members}
        running = await run_in_threadpool(inspector.running_container_ids)
        if running - ids:
            log.info("fleet proof pass missed %d new container(s); retrying", len(running - ids))
            self._safe_remove()
            return None
        proof = build_proof(members, now=self._clock(), ttl=self._ttl)
        if not write_proof(self._path, proof):
            # write_proof already logged the reason. A stale proof must not
            # be reported as covering these ids: fail the pass so run()
            # removes whatever proof is on disk and retries.
            raise RuntimeError("fleet proof write failed")
        return ids

    def _safe_remove(self) -> None:
        try:
            remove_proof(self._path)
        except OSError as e:
            log.warning("fleet proof remove failed: %s", type(e).__name__)

    def shutdown(self) -> None:
        """Remove the proof so it does not outlive this process."""
        self._safe_remove()

    # Consecutive no-write retries (a running id fleet_members never returns)
    # after which run() waits a full interval instead of one watch interval.
    # The id watcher keeps polling regardless, so this only slows down the
    # pass cadence, not detection of new containers.
    _MAX_FAST_RETRIES = 3

    async def run(self, inspector) -> None:
        # A proof left by a previous catalog process must not outlive a restart.
        self._safe_remove()
        covered: set[str] | None = None
        misses = 0
        while True:
            try:
                covered = await self.publish_once(inspector, covered)
            except Exception as e:
                log.warning("fleet proof pass failed: %s", type(e).__name__)
                covered = None
                misses = 0
                # A failed pass must not leave a stale proof valid up to its TTL.
                self._safe_remove()
            else:
                if covered is None:
                    misses += 1
                    delay = self._interval if misses >= self._MAX_FAST_RETRIES else self._watch
                    await asyncio.sleep(delay)
                    continue
                misses = 0
            deadline = time.monotonic() + self._interval
            while time.monotonic() < deadline:
                await asyncio.sleep(self._watch)
                if covered is None:
                    continue
                if await self._new_ids(inspector, covered):
                    self._safe_remove()
                    covered = None
                    break
