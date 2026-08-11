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

async def test_ui_is_painted_before_the_flip():
    client = SlowClient(delay=0.8)
    app = DvwApp(client=client)
    async with app.run_test() as pilot:
        overlay = _overlay(app)
        await _wait_until_hidden(pilot, overlay)
        # No further pause here: whatever the tree shows right now is what
        # was on screen the instant the splash hid. A regression that moved
        # the paint into the handover itself would still show an empty tree
        # at this exact point.
        tree = app.query_one(WorkspaceTree)
        rows = list(tree.root.children)
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
