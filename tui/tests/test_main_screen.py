import os

from dvw_tui.app import DvwApp
from dvw_tui.client import WaitingWindow
from dvw_tui.screens.main import MainScreen, WorkspaceTable

W1 = WaitingWindow("alpha", "@7", "claude", 1754800000)
W2 = WaitingWindow("beta", "@3", "codex", 1754790000)


async def test_q_quits_the_app(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
        await pilot.pause()
        assert not app.is_running


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
        # The inspect fetch is debounced (0.3 s) — wait for it to fire.
        await pilot.pause(0.4)
        pane = app.query_one("#inspect-body")
        text = str(pane.content)
        assert "devpod-alpha" in text


async def test_inspect_debounced_while_scrolling(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)  # initial debounce elapses, alpha fetched
        baseline = len(fake_client.inspect_calls)
        await pilot.press("down")
        await pilot.press("up")
        await pilot.pause()  # well under the 0.3 s debounce
        assert len(fake_client.inspect_calls) == baseline
        await pilot.pause(0.4)  # past the debounce
        assert len(fake_client.inspect_calls) == baseline + 1
        assert fake_client.inspect_calls[-1] == "alpha"


async def test_inspect_renders_from_cache_instantly(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        # Prime the cache: let the debounced fetch for alpha complete.
        await pilot.pause(0.4)
        assert "devpod-alpha" in str(app.query_one("#inspect-body").content)
        baseline = len(fake_client.inspect_calls)
        await pilot.press("down")
        await pilot.press("up")
        await pilot.pause()  # before the debounce — no fetch yet
        text = str(app.query_one("#inspect-body").content)
        assert "devpod-alpha" in text  # rendered straight from cache
        assert len(fake_client.inspect_calls) == baseline


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


async def test_status_header_connected(fake_client, monkeypatch):
    monkeypatch.setenv("DVW_CATALOG_HOST", "testhost")
    # Re-import so the module-level constant picks up the patched env var.
    import importlib
    import dvw_tui.screens.main as main_mod
    importlib.reload(main_mod)
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        header = app.query_one("#status-header")
        text = str(header.content)
        assert "testhost" in text
        assert "connected" in text


async def test_status_header_unreachable(fake_client, monkeypatch):
    monkeypatch.setenv("DVW_CATALOG_HOST", "testhost")
    import importlib
    import dvw_tui.screens.main as main_mod
    importlib.reload(main_mod)
    fake_client.fail = True
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        header = app.query_one("#status-header")
        text = str(header.content)
        assert "testhost" in text
        assert "unreachable" in text


async def test_waiting_section_hidden_when_empty(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.screen.query_one("#waiting-table").display is False


async def test_waiting_section_lists_rows_newest_first(fake_client):
    fake_client.waiting_windows = [W1, W2]
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.screen.query_one("#waiting-table")
        assert table.display is True
        assert table.row_count == 2   # order asserted via first row's cells
        first = table.get_row_at(0)
        assert "alpha" in str(first[0]) and "claude" in str(first[1])


async def test_a_key_attaches_newest(fake_client):
    fake_client.waiting_windows = [W1, W2]
    app = DvwApp(client=fake_client)
    calls = []
    app.do_attach = lambda w: calls.append(w)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("a")
        assert calls == [W1]


async def test_a_key_noop_when_nothing_waiting(fake_client):
    app = DvwApp(client=fake_client)
    calls = []
    app.do_attach = lambda w: calls.append(w)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("a")
        assert calls == []


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
