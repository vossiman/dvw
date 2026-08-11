"""Boot splash: animated DVW overlay that covers MainScreen while
refresh_data() does its first fetch, then hands over with no gap.

The suite-wide `_no_splash_motion` autouse fixture (conftest.py) disables
motion for every other test file so they never need to know the splash
exists. These tests explicitly re-enable it (`DVW_TUI_MOTION=1`) wherever
the animated path matters, and rely on the disabled default where it
doesn't (motion-off and error-path cases).
"""

from __future__ import annotations

import asyncio
import time

import pytest

from dvw_tui.app import DvwApp
from dvw_tui.scanner import FPS
from dvw_tui.screens.main import MainScreen, WorkspaceTree
from dvw_tui.screens.splash import MIN_SPLASH_MS, SplashOverlay

from .conftest import FakeClient

FRAME_MS = 1000 / FPS


class SlowClient(FakeClient):
    """FakeClient whose first fetch takes `delay` seconds — lets tests drive
    the double-buffering (splash-laps-while-loading) path deliberately."""

    def __init__(self, delay: float):
        super().__init__()
        self.delay = delay

    async def workspaces_with_status(self):
        await asyncio.sleep(self.delay)
        return await super().workspaces_with_status()


async def _wait_until_hidden(pilot, overlay: SplashOverlay, timeout: float = 5.0):
    """Poll until the overlay flips, returning the wall-clock time it did.

    Small steps so the moment we observe `display go False` is close to the
    real event; the caller can then inspect state immediately afterwards
    (no further await) to catch anything painted only after the flip.
    """
    start = time.monotonic()
    while overlay.display:
        if time.monotonic() - start > timeout:
            raise AssertionError("splash never hid")
        await pilot.pause(0.01)
    return time.monotonic()


def _overlay(app) -> SplashOverlay:
    return app.query_one(SplashOverlay)


def _main(app) -> MainScreen:
    screen = app.screen
    assert isinstance(screen, MainScreen)
    return screen


# ---------------------------------------------------------------------------
# floor: a near-instant catalog still holds the splash up
# ---------------------------------------------------------------------------

async def test_fast_client_still_holds_the_floor(fake_client, monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "1")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        start = overlay._start  # the widget's own clock origin
        await _wait_until_hidden(pilot, overlay)
        elapsed_ms = (time.monotonic() - start) * 1000
    # Tolerant: "at least the floor", never an exact figure.
    assert elapsed_ms >= MIN_SPLASH_MS


# ---------------------------------------------------------------------------
# double buffering: a slow catalog flips promptly once ready, not on a timer
# ---------------------------------------------------------------------------

async def test_slow_client_flips_within_a_frame_of_readiness(monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "1")
    client = SlowClient(delay=0.8)  # well past MIN_SPLASH_MS
    app = DvwApp(client=client)
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        main = _main(app)

        ready_at = None
        while not main.data_ready:
            await pilot.pause(0.01)
            if ready_at is None and main.data_ready:
                ready_at = time.monotonic()
        ready_at = ready_at or time.monotonic()

        hidden_at = await _wait_until_hidden(pilot, overlay)

    gap_ms = (hidden_at - ready_at) * 1000
    # "Within roughly one frame" — generous multiple so this doesn't flake
    # on a loaded box, but still catches a flip that's tied to some other
    # unrelated timer instead of readiness.
    assert 0 <= gap_ms <= FRAME_MS * 6 + 100


# ---------------------------------------------------------------------------
# no double paint: the tree is populated BEFORE the flip, not after
# ---------------------------------------------------------------------------

async def test_ui_is_painted_before_the_flip(monkeypatch):
    """The most important test in this file: catch a regression back to
    painting the tree at handover instead of in the back buffer.

    Two things this test deliberately does NOT do, because both were tried
    and both let a real regression through:

    1. Poll for `overlay.display is False` and *then* check the tree. A
       deferred paint (e.g. `call_after_refresh(self._render_tree)`
       scheduled right where `data_ready` flips True) completes on the very
       next screen refresh, which is far sooner than any poll interval can
       observe — so the tree looks populated either way.
    2. Wrap `SplashOverlay._tick` and capture state inside the tick that
       flips `display`. `_tick` only runs on the 33ms (`1/FPS`) interval,
       and a `call_after_refresh`-deferred paint completes long before that
       tick next fires — so by the time the wrapped tick runs, the deferred
       paint has *already happened*, regardless of how tightly the capture
       inside the tick is written. The gap this test exists to catch is
       entirely between `data_ready` being set and the paint actually
       running; nothing tied to the splash's own poll cadence can see it.

    Instead this hooks the exact assignment of `MainScreen.data_ready`
    itself — the one moment that must never be reached before the paint has
    already happened — and snapshots the tree synchronously, in the same
    call stack as the assignment, before control returns to the event loop
    and any scheduled callback (`call_after_refresh`, `set_timer`, ...) gets
    a chance to run.
    """
    client = SlowClient(delay=0.8)
    app = DvwApp(client=client)
    captured: dict[str, list] = {}

    def getter(self: MainScreen) -> bool:
        return self.__dict__.get("_data_ready", False)

    def setter(self: MainScreen, value: bool) -> None:
        self.__dict__["_data_ready"] = value
        if value and "rows" not in captured:
            tree = self.query_one(WorkspaceTree)
            captured["rows"] = list(tree.root.children)

    # `data_ready` is a plain instance attribute (set in __init__), not a
    # class attribute, so the class doesn't already have one to override —
    # raising=False lets monkeypatch install the property anyway. It cleans
    # up on the class after the test either way.
    monkeypatch.setattr(MainScreen, "data_ready", property(getter, setter),
                        raising=False)

    async with app.run_test() as pilot:
        overlay = _overlay(app)
        await _wait_until_hidden(pilot, overlay)

    assert "rows" in captured, "data_ready was never set to True"
    rows = captured["rows"]
    assert len(rows) == len(client._workspaces) == 2
    assert rows[0].data == ("ws", "alpha")


# ---------------------------------------------------------------------------
# motion off: one static frame, flip still correct (no floor to protect)
# ---------------------------------------------------------------------------

async def test_motion_disabled_shows_one_static_frame_and_flips_promptly(
        fake_client, monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "0")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        assert len(overlay._frames) == 1
        start = overlay._start
        await _wait_until_hidden(pilot, overlay)
        elapsed_ms = (time.monotonic() - start) * 1000
        tree = app.query_one(WorkspaceTree)
        rows = list(tree.root.children)
    # Nothing to flash, so no floor — well under MIN_SPLASH_MS, but not
    # instantaneous either (still gated on the fetch + one timer tick).
    assert elapsed_ms < MIN_SPLASH_MS
    assert len(rows) == 2


# ---------------------------------------------------------------------------
# a failed first fetch: splash still needs no error path of its own
# ---------------------------------------------------------------------------

async def test_catalog_error_paints_banner_behind_splash_and_does_not_crash(
        fake_client, monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "0")
    fake_client.fail = True
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        await _wait_until_hidden(pilot, overlay)
        await pilot.pause()
        main = _main(app)
        banner = app.query_one("#error-banner")
        assert banner.display is True
        assert "catalog unreachable" in str(banner.content)
        assert app.is_running


# ---------------------------------------------------------------------------
# centring: CSS owns it — no leading blank rows, symmetric margins
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("size", [(60, 20), (80, 24), (100, 30), (140, 45)])
async def test_splash_is_centred_with_no_added_margins(size, monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "1")
    app = DvwApp(client=FakeClient())
    async with app.run_test(size=size) as pilot:
        # Deliberately no pilot.pause(): inspect the very first painted
        # frame, before the fetch can possibly have completed, so the
        # splash is guaranteed still up.
        overlay = _overlay(app)
        assert overlay.display is True
        assert overlay.size == pilot.app.size
        rows = [overlay.render_line(y).text for y in range(overlay.size.height)]
    nonblank = [i for i, row in enumerate(rows) if row.strip()]
    assert nonblank, "expected a painted block, found nothing but blank rows"
    top_margin = nonblank[0]
    bottom_margin = len(rows) - 1 - nonblank[-1]
    assert top_margin > 0  # no leading blank-row trap: still centred, not pinned to row 0
    assert abs(top_margin - bottom_margin) <= 1

    first_row = rows[nonblank[0]]
    left_margin = len(first_row) - len(first_row.lstrip())
    right_margin = len(first_row) - len(first_row.rstrip())
    assert left_margin > 0
    assert abs(left_margin - right_margin) <= 1


# ---------------------------------------------------------------------------
# the 30 Hz timer must stop at the flip, not run for the app's whole life
# ---------------------------------------------------------------------------

async def test_tick_timer_stops_after_the_flip(monkeypatch):
    """Regression test for the splash's `set_interval` never being cancelled.

    Wraps `_tick` to count invocations, waits for the flip, then advances
    several more frame intervals and asserts the count is unchanged — proof
    the widget isn't still waking the event loop 30 times a second after it
    has nothing left to draw.
    """
    monkeypatch.setenv("DVW_TUI_MOTION", "1")
    app = DvwApp(client=FakeClient())
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        calls = {"n": 0}
        original_tick = overlay._tick

        def counting_tick():
            calls["n"] += 1
            original_tick()

        monkeypatch.setattr(overlay, "_tick", counting_tick)

        await _wait_until_hidden(pilot, overlay)
        assert overlay._timer is None, "timer must be cleared at the flip"
        count_at_flip = calls["n"]

        # Advance several more frame intervals — if the timer weren't
        # stopped, _tick would keep firing (and instantly re-return, since
        # `display` is already False and `_ready()` is still True).
        for _ in range(10):
            await pilot.pause(FRAME_MS / 1000)

    assert calls["n"] == count_at_flip


# ---------------------------------------------------------------------------
# palette: the splash follows the configured palette, not a hardcoded one
# ---------------------------------------------------------------------------

async def test_splash_uses_the_configured_palette_not_tokyo(tmp_path, monkeypatch):
    """`app.py` resolves the `palette` setting for the Textual theme; the
    splash must follow the same resolution rather than hardcoding TOKYO.

    Monkeypatches a second palette into `PALETTES` (same technique as
    test_app_settings.py) with a distinctive `accent` so the settled
    frame's colour can be checked against it directly (with motion off,
    `scanner_settled` paints every glyph `bold {accent}` — see
    scanner.py's `_colours`) — proof the widget is actually painting from
    the resolved palette, not merely accepting one.
    """
    import json

    from dvw_tui import palette as P
    from dvw_tui import settings as S
    from dvw_tui.palette import TOKYO

    monkeypatch.setenv("HOME", str(tmp_path))  # never touch the real ~/.config/dvw/

    other = dict(TOKYO)
    other["accent"] = "#222222"
    monkeypatch.setitem(P.PALETTES, "other", other)

    monkeypatch.setenv("DVW_TUI_MOTION", "0")  # single settled frame, easy to inspect
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"palette": "other"}))

    app = DvwApp(client=FakeClient())
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        styles = {str(span.style) for span in overlay._frames[0].spans}

    assert styles == {f"bold {other['accent']}"}
    assert other["accent"] != TOKYO["accent"]
