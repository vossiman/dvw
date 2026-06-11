from dvw_tui.app import DvwApp
from dvw_tui.screens.confirm import ConfirmScreen
from dvw_tui.screens.orphans import OrphansScreen


async def test_orphans_screen_lists_orphans(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("o")
        await pilot.pause()
        assert isinstance(app.screen, OrphansScreen)
        table = app.screen.query_one("#orphans-table")
        assert table.row_count == 1
        assert "devpod-old" in str(table.get_row_at(0)[0])


async def test_orphan_remove_confirms_then_suspends(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("argv", argv))
    monkeypatch.setenv("DVW_CATALOG_HOST", "vossisrv")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("o")
        await pilot.pause()
        await pilot.press("X")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("y")
        await pilot.pause()
        assert calls["argv"] == ["ssh", "vossisrv", "docker", "rm", "-f", "devpod-old"]
