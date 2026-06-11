"""ConnectScreen: preselection, escape, and mode dispatch."""

from textual.widgets import OptionList, Static

from dvw_tui import actions
from dvw_tui.app import DvwApp
from dvw_tui.screens.connect import CONNECT_MODES, ConnectScreen


async def test_connect_screen_lists_modes_and_title(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")          # alpha -> ConnectScreen
        await pilot.pause()
        assert isinstance(app.screen, ConnectScreen)
        title = app.screen.query_one("#connect-title", Static)
        assert "connect alpha via" in str(title.render())
        option_list = app.screen.query_one("#connect-list", OptionList)
        assert option_list.option_count == len(CONNECT_MODES)
        assert [option_list.get_option_at_index(i).id
                for i in range(option_list.option_count)] == ["ssh", "cursor", "both"]


async def test_connect_screen_escape_dismisses_without_call(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(actions, "run_background",
                        lambda argv: calls.setdefault("bg", argv))
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, ConnectScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, ConnectScreen)
        assert calls == {}


async def test_connect_screen_both_suspends_with_both_flag(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")          # alpha -> ConnectScreen (cursor preselected)
        await pilot.pause()
        await pilot.press("down")           # cursor -> both
        await pilot.press("enter")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "alpha", "--both"]


async def test_connect_screen_preselects_from_default_ide(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        # alpha (ide=cursor) -> cursor preselected
        await pilot.press("enter")
        await pilot.pause()
        option_list = app.screen.query_one("#connect-list", OptionList)
        assert option_list.get_option_at_index(option_list.highlighted).id == "cursor"
        await pilot.press("escape")
        await pilot.pause()
        # beta (ide=ssh) -> ssh preselected
        await pilot.press("down")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        option_list = app.screen.query_one("#connect-list", OptionList)
        assert option_list.get_option_at_index(option_list.highlighted).id == "ssh"
