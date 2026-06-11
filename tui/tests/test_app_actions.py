"""App-level action plumbing. Subprocess layers are monkeypatched —
we assert the right argv/mode is chosen, not that devpod runs."""

from dvw_tui import actions
from dvw_tui.app import DvwApp
from dvw_tui.screens.confirm import ConfirmScreen


async def test_connect_gui_runs_background(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(actions, "run_background", lambda argv: calls.setdefault("bg", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")          # alpha, ide=cursor -> background
        await pilot.pause()
        assert calls["bg"] == ["dvw", "alpha"]


async def test_connect_terminal_suspends(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down")           # focus beta, ide=ssh -> suspend
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "beta"]


async def test_stop_runs_suspended(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "stop", "alpha"]


async def test_rebuild_asks_confirmation_then_runs(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("r")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("y")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "rebuild", "alpha"]


async def test_confirm_dismissed_with_n_does_nothing(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("X")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("n")
        await pilot.pause()
        assert "suspended" not in calls
