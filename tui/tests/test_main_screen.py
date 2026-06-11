from dvw_tui.app import DvwApp
from dvw_tui.screens.main import MainScreen, WorkspaceTable


async def test_table_lists_workspaces(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.query_one(WorkspaceTable)
        assert table.row_count == 2
        first = table.get_row_at(0)
        assert "alpha" in str(first[0])


async def test_inspect_pane_shows_focused_workspace(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        pane = app.query_one("#inspect-body")
        text = str(pane.content)
        assert "devpod-alpha" in text


async def test_error_banner_on_catalog_failure(fake_client):
    fake_client.fail = True
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        banner = app.query_one("#error-banner")
        assert banner.display is True
        assert "unreachable" in str(banner.content).lower()


async def test_retry_clears_banner(fake_client):
    fake_client.fail = True
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        fake_client.fail = False
        await pilot.press("R")
        await pilot.pause()
        assert app.query_one("#error-banner").display is False
        assert app.query_one(WorkspaceTable).row_count == 2


async def test_filter_narrows_rows(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("/")
        await pilot.press("b", "e", "t")
        await pilot.press("enter")
        await pilot.pause()
        table = app.query_one(WorkspaceTable)
        assert table.row_count == 1
        assert "beta" in str(table.get_row_at(0)[0])
