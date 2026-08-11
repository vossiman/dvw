"""Boot splash: animated DVW wordmark, layered over MainScreen's own content
while the first catalog fetch runs.

A self-contained widget — not a pushed `Screen` — so `app.screen` never
changes. `MainScreen` mounts it as a normal child and otherwise knows
nothing about how it works; the widget owns its own frames, timer, floor
and readiness check end to end. It sits above the rest of `MainScreen`'s
content on its own CSS layer while `MainScreen.refresh_data()` paints the
tree underneath in the back buffer. The flip is `self.display = False`: a
single visibility toggle with nothing left to render, because the tree is
already fully painted by the time it fires.
"""

from __future__ import annotations

import time
from typing import Callable

from textual.timer import Timer
from textual.widgets import Static

from ..palette import TOKYO
from ..scanner import FPS, SWEEP_PERIOD_MS, scanner_frames, scanner_settled
from ..settings import load_settings, motion_enabled
from ..wordmark import wordmark

# The catalog often answers in a couple of milliseconds (e.g. a warm local
# socket). Without a floor the wordmark would flash up for one frame and
# vanish — a glitch, not a splash. This only protects against a flash of
# *animation*: with motion disabled there's nothing to flash, so the floor
# is dropped entirely (see __init__ below).
MIN_SPLASH_MS = 450


class SplashOverlay(Static):
    """Full-screen animated wordmark; hides itself once the caller is ready.

    `ready` is a zero-arg predicate supplied by the mounting screen (e.g.
    `lambda: self.data_ready`) — the only coupling between the two.
    """

    def __init__(self, ready: Callable[[], bool],
                 palette: dict[str, str] = TOKYO, **kwargs) -> None:
        super().__init__(id="splash-overlay", **kwargs)
        self._ready = ready
        motion = motion_enabled(load_settings())
        art = wordmark()
        if motion:
            # Generated ONCE as a true loop (loop=True) and played modulo:
            # the strip's last frame sits one step before its first, so
            # cycling it has no duplicated frame at the wrap. Regenerating
            # per lap or using the one-shot form would both break that.
            self._frames = scanner_frames(
                art, palette, SWEEP_PERIOD_MS, fps=FPS, loop=True)
            self._min_ms = MIN_SPLASH_MS
        else:
            self._frames = [scanner_settled(art, palette)]
            # No animation, nothing to flash — flip as soon as the data
            # lands instead of holding a static frame for no reason.
            self._min_ms = 0
        self._start = time.monotonic()
        self._frame_index = 0
        # Held so the flip below can stop it — otherwise this 1/FPS timer
        # keeps firing (and waking the event loop) for the app's entire
        # lifetime, long after the overlay has hidden itself and has
        # nothing left to draw. Idle cost matters over ssh and on battery.
        self._timer: Timer | None = None

    def on_mount(self) -> None:
        self.update(self._frames[0])
        self._timer = self.set_interval(1 / FPS, self._tick)

    def _tick(self) -> None:
        # Readiness is checked BEFORE painting the next frame, not after:
        # once the floor has elapsed and the data has landed, the next
        # thing drawn must be the UI, never one more scanner frame.
        elapsed_ms = (time.monotonic() - self._start) * 1000
        if elapsed_ms >= self._min_ms and self._ready():
            self.display = False
            if self._timer is not None:
                self._timer.stop()
                self._timer = None
            return
        self._frame_index += 1
        self.update(self._frames[self._frame_index % len(self._frames)])
