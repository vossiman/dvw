"""Durable record of activity state changes.

The observer's records live in memory, so before this every countdown reset
became unexplainable the moment it scrolled out of the journal or the service
restarted. Changes are appended here as JSONL and served back by
GET /containers/activity/history, so a reset can be read after the fact
without shell access to the host.
"""
from __future__ import annotations

import json
import logging
import os
import threading
from pathlib import Path

from pydantic import BaseModel, Field

log = logging.getLogger(__name__)


class ActivityEvent(BaseModel):
    at: float
    workspace_id: str
    event: str
    state: str
    previous_state: str | None = None
    reasons: list[str] = Field(default_factory=list)
    signals: dict[str, int | None] = Field(default_factory=dict)
    idle_seconds: int | None = None
    note: str | None = None


class ActivityHistory:
    """Append-only JSONL with one rotation. Never raises into the sampler."""

    def __init__(self, path: Path, max_bytes: int = 2 * 1024 * 1024):
        self.path = Path(path)
        self.max_bytes = max_bytes
        self._lock = threading.Lock()

    def append(self, event: ActivityEvent) -> None:
        line = event.model_dump_json() + "\n"
        try:
            with self._lock:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                if self.max_bytes and self.path.exists() \
                        and self.path.stat().st_size + len(line) > self.max_bytes:
                    os.replace(self.path, self.path.with_suffix(self.path.suffix + ".1"))
                with self.path.open("a", encoding="utf-8") as fh:
                    fh.write(line)
        except OSError as exc:
            # Recording is diagnostic; losing a line must never stop sampling.
            log.warning("activity history write failed: %s", type(exc).__name__)

    def tail(self, limit: int = 200, workspace_id: str | None = None) -> list[ActivityEvent]:
        """Newest last. Reads the rotated file too when the current one is short."""
        events: list[ActivityEvent] = []
        for path in (self.path.with_suffix(self.path.suffix + ".1"), self.path):
            try:
                with path.open(encoding="utf-8") as fh:
                    for line in fh:
                        try:
                            event = ActivityEvent.model_validate_json(line)
                        except ValueError:
                            continue
                        if workspace_id is None or event.workspace_id == workspace_id:
                            events.append(event)
            except OSError:
                continue
        return events[-limit:]
