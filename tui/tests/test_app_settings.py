"""The app resolves the `palette` setting into the registered theme.

`PALETTES` currently ships with only "tokyo", so a test that configures
`palette: "tokyo"` and asserts a tokyo-themed app cannot tell resolution
from the old hardcoded `build_theme(palette=TOKYO)` — both produce the same
result. To genuinely prove resolution happens, the "known palette" test
below monkeypatches a second palette into `PALETTES` and asserts the app
picks *that* one up.
"""

from __future__ import annotations

import json

import pytest

from dvw_tui import palette as P
from dvw_tui import settings as S
from dvw_tui.app import DvwApp
from dvw_tui.palette import TOKYO
from dvw_tui.screens.main import MainScreen


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    """Never touch the real ~/.config/dvw/ — same pattern as
    tests/test_settings.py."""
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


def _write_settings(data: dict) -> None:
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps(data))


async def test_known_palette_from_settings_is_applied(fake_client, monkeypatch):
    """A second, monkeypatched palette proves the app actually reads and
    resolves the setting rather than always landing on tokyo."""
    nord = dict(TOKYO)
    nord["bg"] = "#2e3440"
    nord["accent"] = "#88c0d0"
    monkeypatch.setitem(P.PALETTES, "nord", nord)
    _write_settings({"palette": "nord"})

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.theme == "dvw-nord"
        active = app.get_theme(app.theme)
        assert active is not None
        assert active.background == "#2e3440"
        assert active.accent == "#88c0d0"


async def test_unknown_palette_falls_back_to_tokyo(fake_client):
    _write_settings({"palette": "does-not-exist"})

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.theme == "dvw-tokyo"
        active = app.get_theme(app.theme)
        assert active is not None
        assert active.background == TOKYO["bg"]


async def test_corrupt_settings_file_still_boots_themed_tokyo(fake_client):
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text("{not json")

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.theme == "dvw-tokyo"
        assert isinstance(app.screen, MainScreen)


async def test_motion_disabled_boots_cleanly_to_main_screen(fake_client, monkeypatch):
    # Explicit, even though the suite-wide autouse fixture already sets
    # this — the brief calls out that any test asserting motion-off
    # behaviour must not rely on the autouse default silently.
    monkeypatch.setenv("DVW_TUI_MOTION", "0")

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)
