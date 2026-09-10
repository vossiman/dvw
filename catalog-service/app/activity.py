"""Read-only activity observations. No container mutation capability lives here."""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

log = logging.getLogger(__name__)
SIGNALS = {'tmux_sessions': 'tmux', 'cursor_connections': 'cursor',
           'vscode_connections': 'vscode', 'terminals': 'terminal', 'agents': 'agent'}


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


class WorkspaceActivity(BaseModel):
    workspace_id: str
    state: Literal['active', 'idle', 'always-on', 'unknown', 'stopped'] = 'unknown'
    reasons: list[Literal['tmux', 'cursor', 'vscode', 'terminal', 'agent']] = Field(default_factory=list)
    observed_at: float | None = None
    idle_since: float | None = None
    idle_seconds: int | None = None
    timeout_seconds: int = 3600
    remaining_seconds: int | None = None
    observation_only: Literal[True] = True
    signals: dict[str, int | None] = Field(default_factory=dict)


@dataclass
class _Record:
    view: WorkspaceActivity
    observed: float
    identity: tuple
    policy: tuple
    idle_start: float | None = None


class ActivityObserver:
    """Single event-loop owner. Unobserved time is never credited as idle."""
    def __init__(self, max_gap: float = 90):
        self.max_gap = max_gap
        self._records: dict[str, _Record] = {}

    def update(self, workspaces, samples, *, now=None, wall=None):
        now = time.monotonic() if now is None else now
        wall = time.time() if wall is None else wall
        by_id = {s.workspace_id: s for s in samples}
        records = {}
        for w in workspaces:
            s = by_id.get(w.id, ActivitySample(w.id))
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
                                     signals={k: s.signals.get(k) for k in SIGNALS})
            reasons = [reason for key, reason in SIGNALS.items()
                       if isinstance(s.signals.get(key), int) and s.signals[key] > 0]
            start = None
            continuous = False
            if s.running is False:
                view.state = 'stopped'
            elif w.always_on:
                view.state = 'always-on'
                view.reasons = reasons
            elif s.running is True and reasons:
                view.state, view.reasons = 'active', reasons
            elif (s.running is True and s.container_id and s.started_at and s.complete
                  and all(type(s.signals.get(k)) is int and s.signals[k] == 0 for k in SIGNALS)):
                view.state = 'idle'
                continuous = bool(old and old.view.state == 'idle' and old.identity == identity
                                  and old.policy == policy
                                  and 0 <= observed - old.observed <= self.max_gap)
                start = old.idle_start if continuous else observed
                view.idle_since = old.view.idle_since if continuous else observed_wall
                view.idle_seconds = max(0, int(observed - start))
                view.remaining_seconds = max(0, view.timeout_seconds - view.idle_seconds)
            self._log_change(old, view, s, continuous=continuous)
            records[w.id] = _Record(view, observed, identity, policy, start)
        self._records = records

    @staticmethod
    def _log_change(old, view, sample, *, continuous):
        """One line per state or reason change, so a reset is diagnosable later.

        Counts and ids only; the same values the API already serves.
        """
        was = (old.view.state, tuple(old.view.reasons)) if old else None
        detail = sample.note or ', '.join(f'{k}={v}' for k, v in sorted(view.signals.items()))
        if was == (view.state, tuple(view.reasons)):
            # A silent restart of an already-idle countdown: container identity
            # or policy changed, or the gap between samples was too long.
            if view.state == 'idle' and not continuous:
                log.info('activity %s: idle countdown reset [%s]', view.workspace_id, detail)
            return
        log.info('activity %s: %s -> %s%s [%s]', view.workspace_id,
                 was[0] if was else 'new', view.state,
                 ' (' + ','.join(view.reasons) + ')' if view.reasons else '', detail)

    def views(self, workspaces, *, now=None):
        now = time.monotonic() if now is None else now
        result = []
        for w in workspaces:
            r = self._records.get(w.id)
            if (r and 0 <= now - r.observed <= self.max_gap
                    and r.policy == (w.always_on, w.idle_timeout_minutes)):
                result.append(r.view.model_copy(deep=True))
            else:
                result.append(WorkspaceActivity(workspace_id=w.id,
                    state='always-on' if w.always_on else 'unknown',
                    timeout_seconds=w.idle_timeout_minutes * 60))
        return result

    async def run(self, store, inspector, *, interval=30):
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
            await asyncio.sleep(interval)
