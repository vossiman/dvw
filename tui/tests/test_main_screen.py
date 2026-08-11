"""Main screen — tree view: workspaces are folders, tmux windows are rows."""

from dvw_tui.app import DvwApp
from dvw_tui.client import WindowInfo, WorkspaceWindows
from dvw_tui.screens.main import WorkspaceTree


def _tree(app):
    return app.screen.query_one(WorkspaceTree)


def _ws_nodes(app):
    return list(_tree(app).root.children)


def _label(node):
    return str(node.label)


async def test_q_quits_the_app(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
        await pilot.pause()
        assert not app.is_running


# ---------------------------------------------------------------------------
# 1. one node per workspace; running nodes auto-expand with a row per window
# ---------------------------------------------------------------------------

async def test_tree_lists_workspaces_as_nodes(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        nodes = _ws_nodes(app)
        assert len(nodes) == 2
        assert nodes[0].data == ("ws", "alpha")
        assert nodes[1].data == ("ws", "beta")


async def test_workspace_node_label_has_repo_ide_and_state(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        alpha, beta = _ws_nodes(app)
        text = _label(alpha)
        assert "alpha" in text
        assert "vossiman/alpha@main" in text
        assert "cursor" in text
        assert "● running" in text
        assert "⇄ 2" in text          # attached indicator survives the rewrite
        assert "○ stopped" in _label(beta)
        assert "⇄" not in _label(beta)


async def test_running_node_expands_with_one_row_per_window(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        alpha, beta = _ws_nodes(app)
        assert alpha.is_expanded is True
        assert alpha.allow_expand is True
        assert [c.data for c in alpha.children] == [
            ("win", "alpha", "@1"), ("win", "alpha", "@2")]
        assert "claude" in _label(alpha.children[0])
        assert "⏸ waiting" in _label(alpha.children[0])
        # beta has no windows: childless and not expandable
        assert list(beta.children) == []
        assert beta.allow_expand is False


# ---------------------------------------------------------------------------
# 2. waiting count in the status header
# ---------------------------------------------------------------------------

async def test_header_shows_waiting_count(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert "⏸ 1 waiting" in str(app.query_one("#status-header").content)


async def test_header_has_no_waiting_marker_when_none_waiting(fake_client):
    fake_client.window_map["alpha"].windows[0].waiting_since = None
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert "⏸" not in str(app.query_one("#status-header").content)


# ---------------------------------------------------------------------------
# 3. Enter routing: window row attaches, workspace node connects
# ---------------------------------------------------------------------------

async def test_enter_on_window_row_attaches_that_window(fake_client, monkeypatch):
    calls = []
    monkeypatch.setattr(
        DvwApp, "_run_suspended",
        lambda self, argv, pause_on_fail=True: calls.append(argv) or 0)
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down")        # alpha -> its first window row
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("win", "alpha", "@1")
        await pilot.press("enter")
        await pilot.pause()
    assert calls == [["dvw", "alpha", "--ssh", "--window", "@1"]]


async def test_enter_on_workspace_node_connects(fake_client, monkeypatch):
    calls = []
    monkeypatch.setattr(
        DvwApp, "_run_suspended",
        lambda self, argv, pause_on_fail=True: calls.append(argv) or 0)
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
    assert calls == [["dvw", "alpha", "--ssh"]]


async def test_enter_does_not_toggle_the_node(fake_client, monkeypatch):
    """Tree's default enter-select (auto_expand) must not fire — Enter is a
    screen priority binding that routes instead."""
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True: 0)
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert _ws_nodes(app)[0].is_expanded is True


# ---------------------------------------------------------------------------
# 4. workspace actions from a focused window row act on the parent
# ---------------------------------------------------------------------------

async def test_stop_from_window_row_targets_parent_workspace(fake_client, monkeypatch):
    calls = []
    monkeypatch.setattr(
        DvwApp, "_run_suspended",
        lambda self, argv, pause_on_fail=True: calls.append(argv) or 0)
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down", "down")   # second window row of alpha
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("win", "alpha", "@2")
        await pilot.press("s")
        await pilot.pause()
    assert calls == [["dvw", "stop", "alpha"]]


async def test_focused_workspace_resolves_from_window_row(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down")
        await pilot.pause()
        assert app.screen.focused_workspace().id == "alpha"
        assert app.screen.focused_workspace_id() == "alpha"


# ---------------------------------------------------------------------------
# 5. `a` attaches the newest waiting window across all workspaces
# ---------------------------------------------------------------------------

async def test_a_key_attaches_newest_waiting_across_workspaces(fake_client):
    fake_client.window_map["beta"] = WorkspaceWindows(
        "beta", attached=0,
        windows=[WindowInfo("@3", "codex", waiting_since=1754900000)])
    app = DvwApp(client=fake_client)
    calls = []
    app.do_attach = lambda ws, win: calls.append((ws, win))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
    assert calls == [("beta", "@3")]   # newer waiting_since than alpha's @1


async def test_a_key_notifies_when_nothing_waiting(fake_client):
    fake_client.window_map = {}
    app = DvwApp(client=fake_client)
    calls = []
    notes = []
    app.do_attach = lambda ws, win: calls.append((ws, win))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.screen.notify = lambda msg, **kw: notes.append(msg)
        await pilot.press("a")
        await pilot.pause()
    assert calls == []
    assert notes == ["nothing waiting"]


async def test_a_key_noop_after_workspace_fetch_fails(fake_client):
    app = DvwApp(client=fake_client)
    calls = []
    app.do_attach = lambda ws, win: calls.append((ws, win))
    async with app.run_test() as pilot:
        await pilot.pause()
        assert "⏸ 1 waiting" in str(app.query_one("#status-header").content)
        fake_client.fail = True
        app.screen.refresh_data()
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
    assert calls == []


# ---------------------------------------------------------------------------
# 6. manual collapse survives a refresh
# ---------------------------------------------------------------------------

async def test_manual_collapse_survives_refresh(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("space")          # collapse alpha
        await pilot.pause()
        assert _ws_nodes(app)[0].is_expanded is False
        app.screen.refresh_data()
        await pilot.pause()
        assert _ws_nodes(app)[0].is_expanded is False
        await pilot.press("space")          # expand again
        await pilot.pause()
        app.screen.refresh_data()
        await pilot.pause()
        assert _ws_nodes(app)[0].is_expanded is True


async def test_collapse_memory_pruned_when_workspace_disappears(fake_client):
    """A collapsed id shouldn't silently pre-collapse a later, unrelated
    workspace that happens to reuse the same id after the original one
    dropped out of the fixture."""
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("space")          # collapse alpha
        await pilot.pause()
        assert _ws_nodes(app)[0].is_expanded is False

        original_workspaces = list(fake_client._workspaces)
        fake_client._workspaces = [w for w in original_workspaces if w.id != "alpha"]
        app.screen.refresh_data()
        await pilot.pause()
        assert [n.data for n in _ws_nodes(app)] == [("ws", "beta")]

        fake_client._workspaces = original_workspaces
        app.screen.refresh_data()
        await pilot.pause()
        alpha = _ws_nodes(app)[0]
        assert alpha.data == ("ws", "alpha")
        assert alpha.is_expanded is True


# ---------------------------------------------------------------------------
# 7. filter
# ---------------------------------------------------------------------------

async def test_filter_narrows_workspace_nodes(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("/")
        await pilot.press("b", "e", "t")
        await pilot.press("enter")
        await pilot.pause()
        nodes = _ws_nodes(app)
        assert len(nodes) == 1
        assert nodes[0].data == ("ws", "beta")


async def test_filter_keeps_windows_with_their_parent(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("/")
        await pilot.press("a", "l", "p")
        await pilot.press("enter")
        await pilot.pause()
        nodes = _ws_nodes(app)
        assert len(nodes) == 1
        assert [c.data for c in nodes[0].children] == [
            ("win", "alpha", "@1"), ("win", "alpha", "@2")]


# ---------------------------------------------------------------------------
# 8. catalog outage / old server
# ---------------------------------------------------------------------------

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
        assert len(_ws_nodes(app)) == 2


async def test_old_server_without_windows_endpoint_renders_folders(fake_client):
    fake_client.window_map = {}
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        nodes = _ws_nodes(app)
        assert len(nodes) == 2
        assert all(list(n.children) == [] for n in nodes)
        assert all(n.allow_expand is False for n in nodes)
        header = str(app.query_one("#status-header").content)
        assert "⏸" not in header
        assert "connected" in header


async def test_status_header_connected(fake_client, monkeypatch):
    # main_mod._CATALOG_HOST is read once at import time; patch the module
    # attribute directly rather than reloading the module — a reload swaps
    # in a fresh MainScreen class object, breaking isinstance checks (e.g.
    # WorkspaceTree._on_click) for any test that imports the *original*
    # class and runs later in the same process (see PR #36-class bug).
    import dvw_tui.screens.main as main_mod
    monkeypatch.setattr(main_mod, "_CATALOG_HOST", "testhost")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        text = str(app.query_one("#status-header").content)
        assert "testhost" in text
        assert "connected" in text


async def test_status_header_unreachable(fake_client, monkeypatch):
    import dvw_tui.screens.main as main_mod
    monkeypatch.setattr(main_mod, "_CATALOG_HOST", "testhost")
    fake_client.fail = True
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        text = str(app.query_one("#status-header").content)
        assert "testhost" in text
        assert "unreachable" in text


# ---------------------------------------------------------------------------
# 9. cursor preservation across a refresh
# ---------------------------------------------------------------------------

async def test_cursor_stays_on_workspace_across_refresh(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down", "down", "down")   # @1, @2, beta
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("ws", "beta")
        app.screen.refresh_data()
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("ws", "beta")


async def test_cursor_stays_on_window_row_across_refresh(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down", "down")
        await pilot.pause()
        app.screen.refresh_data()
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("win", "alpha", "@2")


async def test_cursor_falls_back_to_parent_when_window_disappears(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down", "down")
        await pilot.pause()
        fake_client.window_map["alpha"].windows.pop()   # @2 goes away
        app.screen.refresh_data()
        await pilot.pause()
        assert _tree(app).cursor_node.data == ("ws", "alpha")


# ---------------------------------------------------------------------------
# inspect pane (unchanged behaviour, driven from tree highlights)
# ---------------------------------------------------------------------------

async def test_inspect_pane_shows_attached_line(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)             # inspect debounce
        pane = app.query_one("#inspect-body")
        assert "attached" in str(pane.content)
        assert "2 clients" in str(pane.content)


async def test_inspect_pane_shows_focused_workspace(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        assert "devpod-alpha" in str(app.query_one("#inspect-body").content)


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


async def test_inspect_refreshes_on_stationary_cursor_refresh(fake_client):
    """Regression: Tree.watch_cursor_line only posts NodeHighlighted when the
    cursor's line number actually changes. On the steady-state 10s poll the
    cursor stays put (still line 0, on alpha), so _render_tree must call
    _update_inspect() explicitly — relying on NodeHighlighted alone leaves
    the inspect pane stale."""
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)             # initial debounce elapses
        pane = app.query_one("#inspect-body")
        assert "2 clients" in str(pane.content)

        fake_client._workspaces[0].attached = 9   # alpha: 2 -> 9 clients
        app.screen.refresh_data()          # cursor never moves off alpha
        await pilot.pause(0.4)             # past the debounce
        assert "9 clients" in str(app.query_one("#inspect-body").content)


async def test_inspect_renders_from_cache_instantly(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        assert "devpod-alpha" in str(app.query_one("#inspect-body").content)
        baseline = len(fake_client.inspect_calls)
        await pilot.press("down")
        await pilot.press("up")
        await pilot.pause()  # before the debounce — no fetch yet
        assert "devpod-alpha" in str(app.query_one("#inspect-body").content)
        assert len(fake_client.inspect_calls) == baseline
