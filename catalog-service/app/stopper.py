"""Automatic stop of idle workspace containers.

The observer owns idle credit; this module only asks it, rechecks, and stops.
It keeps no countdown of its own, so there is no second opinion to drift.
"""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field

from starlette.concurrency import run_in_threadpool

from .activity import ActivityObserver, ActivitySample

log = logging.getLogger(__name__)


class StopRefused(Exception):
    """Docker or the proxy answered, and the answer was no."""


class StopUncertain(Exception):
    """No answer arrived. The container may or may not have stopped."""


@dataclass
class _Attempt:
    container_id: str
    started_at: str
    idle_seconds: int | None
    # Set when the stop call has returned, whatever the outcome.
    returned: asyncio.Event = field(default_factory=asyncio.Event)


class Stopper:
    def __init__(self, observer: ActivityObserver, inspector, *, enforce: bool,
                 grace: int = 10, backoff: float = 600.0,
                 invalidate=lambda ws_id: None,
                 clock=time.monotonic, wall=time.time):
        self.observer = observer
        self.inspector = inspector
        self.enforce = enforce
        self.grace = grace
        self.backoff = backoff
        self._invalidate = invalidate
        self._clock = clock
        self._wall = wall
        # Stops dispatched and not yet settled, by workspace id.
        self._pending: dict[str, _Attempt] = {}
        self._retry_after: dict[str, float] = {}

    async def run_pass(self, workspaces) -> None:
        """Called after each observer pass. One stop at a time."""
        for ws_id in list(self._pending):
            await self._reconcile(ws_id)
        if not self.enforce:
            return
        by_id = {w.id: w for w in workspaces}
        for view in self.observer.views(workspaces, now=self._clock()):
            w = by_id[view.workspace_id]
            if view.state != 'idle' or view.remaining_seconds != 0 or w.always_on:
                continue
            if w.id in self._pending or self._clock() < self._retry_after.get(w.id, 0.0):
                continue
            await self._attempt(w)

    async def wait(self, ws_id: str, timeout: float = 25.0) -> bool:
        """Let a connecting client wait out a stop. True when none is pending after."""
        attempt = self._pending.get(ws_id)
        if attempt is None:
            return True
        try:
            await asyncio.wait_for(attempt.returned.wait(), timeout)
        except asyncio.TimeoutError:
            return False
        if ws_id in self._pending:
            await self._reconcile(ws_id)
        return ws_id not in self._pending

    async def _attempt(self, w) -> None:
        before = self.observer.credit(w.id)
        if before is None:
            return
        try:
            samples = await run_in_threadpool(self.inspector.activity_many, [w.id], True)
        except Exception:
            log.warning('activity %s: recheck before stop failed', w.id)
            samples = []
        sample = samples[0] if samples else ActivitySample(w.id)
        # The recheck is an ordinary observation: activity clears the credit.
        self.observer.update_one(w, sample, now=self._clock(), wall=self._wall())
        # From here to the executor submission nothing awaits, so a touch
        # cannot land between this final check and the dispatch.
        view = self.observer.views([w], now=self._clock())[0]
        if (self.observer.credit(w.id) != before or view.state != 'idle'
                or view.remaining_seconds != 0):
            return
        container_id, started_at = before[1]
        attempt = _Attempt(container_id, started_at, view.idle_seconds)
        self._pending[w.id] = attempt
        call = asyncio.get_running_loop().run_in_executor(
            None, self.inspector.stop_container, container_id, self.grace)
        try:
            await call
        except StopRefused as exc:
            self._settle(w.id, 'failed', note=str(exc)[:200])
        except StopUncertain:
            # Nothing is assumed. The next pass, or a waiting touch, reconciles.
            log.info('activity %s: stop outcome uncertain', w.id)
        except asyncio.CancelledError:
            self._pending.pop(w.id, None)
            raise
        except Exception:
            log.warning('activity %s: stop outcome uncertain (unexpected error)', w.id)
        else:
            self._settle(w.id, 'stopped')
        finally:
            attempt.returned.set()

    async def _reconcile(self, ws_id: str) -> None:
        """Settle an uncertain stop against the exact container it targeted."""
        attempt = self._pending.get(ws_id)
        if attempt is None or not attempt.returned.is_set():
            return
        try:
            state = await run_in_threadpool(self.inspector.container_state, attempt.container_id)
        except Exception:
            return                      # stays pending; no new stop meanwhile
        if ws_id not in self._pending:
            return
        if state is None or state[0] != 'running' or state[1] != attempt.started_at:
            # Not running, gone, or a later incarnation: the stop worked.
            self._settle(ws_id, 'stopped', note='reconciled')
        else:
            self._settle(ws_id, 'failed', note='still running after an unanswered stop')

    def _settle(self, ws_id: str, result: str, note: str | None = None) -> None:
        attempt = self._pending.pop(ws_id, None)
        if attempt is None:
            return
        self.observer.record_stop(ws_id, result, at=self._wall(),
                                  idle_seconds=attempt.idle_seconds, note=note)
        if result == 'stopped':
            self._retry_after.pop(ws_id, None)
            self._invalidate(ws_id)
            self.inspector.forget_snapshot(attempt.container_id)
        else:
            self._retry_after[ws_id] = self._clock() + self.backoff
