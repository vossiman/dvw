from textual.widgets import OptionList

from dvw_tui.app import DvwApp
from dvw_tui.screens.menu import MENU_ITEMS, MenuScreen
from dvw_tui.screens.pair import PairScreen


async def test_menu_opens_and_lists_actions(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        assert isinstance(app.screen, MenuScreen)
        # The menu is driven by MENU_ITEMS: every action word appears in
        # its labels and the OptionList carries exactly those options.
        joined = " ".join(label for _action, label in MENU_ITEMS)
        for word in ("connect", "pair", "stop", "start", "rebuild", "remove",
                     "new", "doctor", "orphans"):
            assert word in joined
        option_list = app.screen.query_one("#menu-list", OptionList)
        assert option_list.option_count == len(MENU_ITEMS)


async def test_menu_escape_closes(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, MenuScreen)


async def test_menu_select_dispatches(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "do_simple_action",
        lambda self, name, ws: calls.setdefault("action", (name, ws.id)))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        await pilot.press("down")        # connect -> pair_paseo
        await pilot.press("down")        # pair_paseo -> stop
        await pilot.press("enter")
        await pilot.pause()
        assert calls["action"] == ("stop", "alpha")


async def test_menu_pair_paseo_pushes_pair_screen(fake_client, monkeypatch):
    monkeypatch.setattr(
        "dvw_tui.actions.run_captured",
        lambda argv: type("R", (), {"ok": True, "output": "qr", "returncode": 0})(),
    )
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("x")           # open context menu
        await pilot.pause()
        await pilot.press("down")        # connect -> pair_paseo
        await pilot.press("enter")       # select pair_paseo
        await pilot.pause()
        assert isinstance(app.screen, PairScreen)
        assert app.screen._workspace_id == "alpha"
