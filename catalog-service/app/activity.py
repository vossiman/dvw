"""Activity observations and idle credit. No container mutation capability lives here."""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from .activity_history import ActivityEvent, ActivityHistory

log = logging.getLogger(__name__)
# One flaky probe (timeout, partial report) must not restart an hour-long
# countdown. Idle credit earned before such a gap is kept, the gap itself is
# never credited, and a second unknown in a row still resets.
UNKNOWN_TOLERANCE = 1
SIGNALS = {'tmux_sessions': 'tmux', 'cursor_connections': 'cursor',
           'vscode_connections': 'vscode', 'terminals': 'terminal', 'agents': 'agent'}
# Exemption, not activity: a running T3 server. Null blocks "idle" like any signal.
T3 = 't3_servers'


@dataclass
class ActivitySample:
    workspace_id: str
    container_id: str | None = None
    started_at: str | None = None
    running: bool | None = None
    signals: dict[str, int | None] = field(default_factory=dict)
    complete: bool = True
    sampled_at: float | None = None
    note: str | None = None


class StopRecord(BaseModel):
    result: Literal['stopped', 'failed']
    at: float
    idle_seconds: int | None = None


class WorkspaceActivity(BaseModel):
    workspace_id: str
    state: Literal['active', 'idle', 'always-on', 'unknown', 'stopped'] = 'unknown'
    reasons: list[Literal['tmux', 'cursor', 'vscode', 'terminal', 'agent', 't3']] = Field(default_factory=list)
    observed_at: float | None = None
    idle_since: float | None = None
    idle_seconds: int | None = None
    timeout_seconds: int = 3600
    remaining_seconds: int | None = None
    observation_only: bool = True
    signals: dict[str, int | None] = Field(default_factory=dict)
    stop: StopRecord | None = None


@dataclass
class _Record:
    view: WorkspaceActivity
    observed: float
    identity: tuple
    policy: tuple
    idle_start: float | None = None
    # (idle_start, idle_since wall, last idle observation, unknowns so far)
    # while an idle countdown is carried across unknown samples.
    carry: tuple | None = None


class ActivityObserver:
    """Single event-loop owner. Unobserved time is never credited as idle."""
    def __init__(self, max_gap: float = 90, history: ActivityHistory | None = None,
                 enforce: bool = False):
        self.max_gap = max_gap
        self.history = history
        self.enforce = enforce
        self._records: dict[str, _Record] = {}
        self._stops: dict[str, StopRecord] = {}

    def update(self, workspaces, samples, *, now=None, wall=None):
        """A full pass: every workspace gets a transition, absent ones are pruned."""
        now = time.monotonic() if now is None else now
        wall = time.time() if wall is None else wall
        by_id = {s.workspace_id: s for s in samples}
        self._records = {
            w.id: self._transition(w, by_id.get(w.id, ActivitySample(w.id)), now, wall)
            for w in workspaces}

    def update_one(self, workspace, sample, *, now=None, wall=None):
        """Apply one sample with the same rules, leaving every other record alone."""
        now = time.monotonic() if now is None else now
        wall = time.time() if wall is None else wall
        self._records[workspace.id] = self._transition(workspace, sample, now, wall)

    def reset(self, ws_id: str) -> None:
        """Forget the countdown: the next idle sample starts a new one."""
        self._records.pop(ws_id, None)

    def credit(self, ws_id: str):
        """What identifies the current countdown, or None when not idle."""
        r = self._records.get(ws_id)
        if r is None or r.view.state != 'idle':
            return None
        return (r.idle_start, r.identity, r.policy)

    def record_stop(self, ws_id, result, *, at, idle_seconds, note=None):
        self._stops[ws_id] = StopRecord(result=result, at=at, idle_seconds=idle_seconds)
        log.info('activity %s: automatic stop %s%s', ws_id, result,
                 f' [{note}]' if note else '')
        if self.history is not None:
            self.history.append(ActivityEvent(
                at=at, workspace_id=ws_id,
                event='stop' if result == 'stopped' else 'stop-failed',
                state='stopped' if result == 'stopped' else 'idle',
                previous_state='idle', idle_seconds=idle_seconds, note=note))

    def _transition(self, w, s, now, wall) -> _Record:
        observed = s.sampled_at if s.sampled_at is not None else now
        if not 0 <= now - observed <= self.max_gap:
            s = ActivitySample(w.id)
            observed = now
        observed_wall = wall - (now - observed)
        old = self._records.get(w.id)
        identity = (s.container_id, s.started_at)
        policy = (w.always_on, w.idle_timeout_minutes)
        view = WorkspaceActivity(workspace_id=w.id, observed_at=observed_wall,
                                 timeout_seconds=w.idle_timeout_minutes * 60,
                                 observation_only=not self.enforce,
                                 signals={k: s.signals.get(k) for k in (*SIGNALS, T3)})
        reasons = [reason for key, reason in SIGNALS.items()
                   if isinstance(s.signals.get(key), int) and s.signals[key] > 0]
        t3 = s.signals.get(T3)
        start = None
        carry = None
        continuous = False
        same = bool(old and old.identity == identity and old.policy == policy
                    and 0 <= observed - old.observed <= self.max_gap)
        if s.running is False:
            view.state = 'stopped'
        elif w.always_on:
            view.state = 'always-on'
            view.reasons = reasons
        elif s.running is True and type(t3) is int and t3 > 0:
            view.state, view.reasons = 'always-on', [*reasons, 't3']
        elif s.running is True and reasons:
            view.state, view.reasons = 'active', reasons
        elif (s.running is True and s.container_id and s.started_at and s.complete
              and type(t3) is int and t3 == 0
              and all(type(s.signals.get(k)) is int and s.signals[k] == 0 for k in SIGNALS)):
            view.state = 'idle'
            continuous = same and old.view.state == 'idle'
            if continuous:
                start, view.idle_since = old.idle_start, old.view.idle_since
            elif same and old.carry:
                # Resume the carried countdown, shifted so the time since
                # the last idle observation is not credited.
                carried_start, view.idle_since, last_idle, _ = old.carry
                start = carried_start + (observed - last_idle)
                continuous = True
            else:
                start, view.idle_since = observed, observed_wall
            view.idle_seconds = max(0, int(observed - start))
            view.remaining_seconds = max(0, view.timeout_seconds - view.idle_seconds)
        elif s.running is True and s.container_id and same:
            if old.view.state == 'idle':
                carry = (old.idle_start, old.view.idle_since, old.observed, 1)
            elif old.carry and old.carry[3] < UNKNOWN_TOLERANCE:
                carry = (*old.carry[:3], old.carry[3] + 1)
            if carry and carry[3] > UNKNOWN_TOLERANCE:
                carry = None
        self._record_change(old, view, s, observed_wall, continuous=continuous)
        return _Record(view, observed, identity, policy, start, carry)

    def _record_change(self, old, view, sample, at, *, continuous):
        """One entry per state or reason change, so a reset is diagnosable later.

        Counts and ids only; the same values the API already serves.
        """
        was = (old.view.state, tuple(old.view.reasons)) if old else None
        detail = sample.note or ', '.join(f'{k}={v}' for k, v in sorted(view.signals.items()))
        if was == (view.state, tuple(view.reasons)):
            # A silent restart of an already-idle countdown: container identity
            # or policy changed, or the gap between samples was too long.
            if view.state != 'idle' or continuous:
                return
            event = 'reset'
            log.info('activity %s: idle countdown reset [%s]', view.workspace_id, detail)
        else:
            event = 'change'
            log.info('activity %s: %s -> %s%s [%s]', view.workspace_id,
                     was[0] if was else 'new', view.state,
                     ' (' + ','.join(view.reasons) + ')' if view.reasons else '', detail)
        if self.history is not None:
            self.history.append(ActivityEvent(
                at=at, workspace_id=view.workspace_id, event=event, state=view.state,
                previous_state=was[0] if was else None, reasons=list(view.reasons),
                signals=dict(view.signals), idle_seconds=view.idle_seconds,
                note=sample.note))

    def views(self, workspaces, *, now=None):
        now = time.monotonic() if now is None else now
        result = []
        for w in workspaces:
            r = self._records.get(w.id)
            if (r and 0 <= now - r.observed <= self.max_gap
                    and r.policy == (w.always_on, w.idle_timeout_minutes)):
                view = r.view.model_copy(deep=True)
            else:
                view = WorkspaceActivity(workspace_id=w.id,
                    state='always-on' if w.always_on else 'unknown',
                    timeout_seconds=w.idle_timeout_minutes * 60,
                    observation_only=not self.enforce)
            view.stop = self._stops.get(w.id)
            result.append(view)
        return result

    async def run(self, store, inspector, *, interval=30, after_pass=None):
        """One sampling pass at a time, independent of UI. The deployed Docker
        proxy bounds exec relays; stale views expire even while a pass waits."""
        while True:
            workspaces = store.list_workspaces()
            try:
                samples = await run_in_threadpool(inspector.activity_many, [w.id for w in workspaces])
            except Exception:
                # No raw container data or exception content in logs.
                log.warning('activity observation failed')
                samples = []
            self.update(workspaces, samples)
            if after_pass is not None:
                try:
                    await after_pass(workspaces)
                except Exception:
                    log.warning('activity stop pass failed')
            await asyncio.sleep(interval)
