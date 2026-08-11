"""Main screen: workspace tree (left) + inspect pane (right).

The tree is one level deep: each visible workspace is a folder node, each of
its tmux windows a child row. Node `data` is the routing key —
`("ws", workspace_id)` or `("win", workspace_id, window_id)` — every action
reads it rather than a row index, so window rows resolve to their parent
workspace for free.
"""

from __future__ import annotations

import os
import time

from rich.text import Text
from textual import events, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import Screen
from textual.timer import Timer
from textual.widgets import Footer, Input, Static, Tree
from textual.widgets.tree import TreeNode

from ..client import CatalogError, Workspace, WorkspaceWindows
from ..render import (
    ACCENT,
    GREEN,
    RED,
    SUBTLE,
    ide_cell,
    inspect_lines,
    state_cell,
    window_label,
)

_CATALOG_HOST = os.environ.get("DVW_CATALOG_HOST", "vossisrv")

# Node data discriminators.
NodeData = tuple  # ("ws", ws_id) | ("win", ws_id, window_id)


class WorkspaceTree(Tree[NodeData]):
    """Left panel — workspaces as folders, tmux windows as child rows.

    Single-click moves the cursor. Double-click activates the node (connect /
    attach), mirroring the old table's `event.chain == 2` rule — a second slow
    click on the already-focused row must *not* count as a select. Clicks on
    the expand arrow still toggle.
    """

    async def _on_click(self, event: events.Click) -> None:
        async with self.lock:
            meta = event.style.meta
            if "line" not in meta:
                return
            line = meta["line"]
            node = self.get_node_at_line(line)
            if node is None:
                return
            if meta.get("toggle", False):
                self._toggle_node(node)
                return
            self.cursor_line = line
            event.stop()
            if event.chain != 2:
                return
            screen = self.screen
            if isinstance(screen, MainScreen):
                screen.activate_node(node)


class MainScreen(Screen):
    BINDINGS = [
        Binding("enter", "connect", "ssh", priority=True),
        Binding("a", "attach_waiting", "attach ⏸"),
        Binding("s", "stop", "stop"),
        Binding("S", "start", "start"),
        Binding("r", "rebuild", "rebuild"),
        Binding("X", "remove", "remove"),
        Binding("n", "new", "new"),
        Binding("d", "doctor", "doctor"),
        Binding("o", "orphans", "orphans"),
        Binding("x", "menu", "menu"),
        Binding("slash", "filter", "filter", key_display="/"),
        Binding("R", "refresh", "refresh"),
        Binding("q", "app.quit", "quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._workspaces: list[Workspace] = []
        self._windows: dict[str, WorkspaceWindows] = {}
        # Workspace ids the user collapsed by hand — nodes are rebuilt from
        # scratch on every refresh, so the expanded state has to live here.
        self._collapsed: set[str] = set()
        self._filter = ""
        # Last inspect response per workspace id; rendered instantly on
        # highlight, freshened by a debounced re-fetch.
        self._inspect_cache: dict[str, dict] = {}
        self._inspect_timer: Timer | None = None

    # ---- layout -----------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static(id="status-header")
        yield Static(id="error-banner")
        with Horizontal(id="panes"):
            with Vertical(id="left"):
                yield Static(" dvw — workspaces", id="left-title")
                yield WorkspaceTree("workspaces", id="ws-tree")
                yield Input(placeholder="filter…", id="filter-input")
            with VerticalScroll(id="right"):
                yield Static(" inspect", id="right-title")
                yield Static(id="inspect-body")
        yield Footer()

    def on_mount(self) -> None:
        self._update_header(connected=False)
        self.query_one("#error-banner", Static).display = False
        self.query_one("#filter-input", Input).display = False
        tree = self.query_one(WorkspaceTree)
        tree.show_root = False
        tree.guide_depth = 2
        self.set_interval(10.0, self.refresh_data)
        self.refresh_data()

    # ---- data -------------------------------------------------------------

    @work(exclusive=True)
    async def refresh_data(self) -> None:
        try:
            self._workspaces = await self.app.client.workspaces_with_status()
        except CatalogError as exc:
            self._show_error(f"catalog unreachable — {exc} — R to retry")
            # Fail closed: don't leave stale waiting badges visible (or
            # attachable via `a`) once the workspace fetch itself failed.
            self._windows = {}
            self._update_header(connected=False)
            self._render_tree()
            return
        # Fail-open by contract: an old server (no /containers/windows)
        # yields {} and the folders simply render childless.
        self._windows = await self.app.client.windows()
        self._hide_error()
        self._update_header(connected=True)
        self._render_tree()

    def _visible_workspaces(self) -> list[Workspace]:
        if not self._filter:
            return self._workspaces
        needle = self._filter.lower()
        return [w for w in self._workspaces
                if needle in w.id.lower() or needle in w.short_repo.lower()]

    def _workspace_label(self, w: Workspace, expandable: bool) -> Text:
        # Textual only draws the ▼/▶ toggle for expandable nodes; pad the
        # childless ones so every workspace name starts in the same column.
        text = Text("" if expandable else "  ")
        text.append(w.id, style=f"bold {ACCENT}")
        text.append(f"  {w.short_repo}@{w.branch}", style=SUBTLE)
        text.append("  ")
        text.append_text(ide_cell(w.ide))
        text.append("  ")
        text.append_text(state_cell(w.liveness, w.attached))
        return text

    def _render_tree(self) -> None:
        tree = self.query_one(WorkspaceTree)
        prev = self._cursor_key()
        now = int(time.time())
        tree.clear()
        if not tree.root.is_expanded:
            tree.root.expand()
        # Drop collapse memory for workspaces that no longer exist, so a
        # since-removed id doesn't silently pre-collapse a later workspace
        # that happens to reuse it.
        self._collapsed &= {w.id for w in self._workspaces}
        for w in self._visible_workspaces():
            snapshot = self._windows.get(w.id)
            windows = snapshot.windows if snapshot is not None else []
            node = tree.root.add(
                self._workspace_label(w, bool(windows)),
                data=("ws", w.id),
                expand=bool(windows) and w.id not in self._collapsed,
                allow_expand=bool(windows),
            )
            for win in windows:
                node.add_leaf(window_label(win, now),
                              data=("win", w.id, win.window_id))
        self._restore_cursor(tree, prev)
        # move_cursor()'s NodeHighlighted only fires when the target line
        # number differs from the previous one — on a steady-state refresh
        # the cursor typically lands back on the same line, so that event
        # never posts. Refresh explicitly every time; the occasional extra
        # call on a genuine cursor move is harmless (it just resets the
        # 0.3s debounce).
        self._update_inspect()

    # ---- cursor -----------------------------------------------------------

    def _cursor_key(self) -> NodeData | None:
        node = self.query_one(WorkspaceTree).cursor_node
        return node.data if node is not None else None

    def _restore_cursor(self, tree: WorkspaceTree, prev: NodeData | None) -> None:
        """Put the cursor back on the same node after a rebuild.

        Falls back to the parent workspace when the exact window row is gone
        (or hidden behind a collapsed folder), and to the first node when the
        workspace itself vanished — never leaves the tree cursor-less.
        """
        target: TreeNode[NodeData] | None = None
        if prev is not None:
            for node in tree.root.children:
                if node.data[1] != prev[1]:
                    continue
                target = node
                if prev[0] == "win" and node.is_expanded:
                    for child in node.children:
                        if child.data[2] == prev[2]:
                            target = child
                            break
                break
        if target is None and tree.root.children:
            target = tree.root.children[0]
        # move_cursor() addresses nodes by their line number, which Tree only
        # assigns while (re)building its line cache — freshly added nodes are
        # still at -1. Touching `last_line` forces that build first, otherwise
        # every restore would clamp to line 0.
        tree.last_line  # noqa: B018
        tree.move_cursor(target)

    def focused_workspace_id(self) -> str | None:
        """Workspace id under the cursor — a window row resolves to its parent."""
        key = self._cursor_key()
        return None if key is None else str(key[1])

    def focused_workspace(self) -> Workspace | None:
        ws_id = self.focused_workspace_id()
        for w in self._workspaces:
            if w.id == ws_id:
                return w
        return None

    # ---- tree events ------------------------------------------------------

    def on_tree_node_highlighted(self, event: Tree.NodeHighlighted[NodeData]) -> None:
        self._update_inspect()

    def on_tree_node_collapsed(self, event: Tree.NodeCollapsed[NodeData]) -> None:
        data = event.node.data
        if data is not None and data[0] == "ws":
            self._collapsed.add(data[1])

    def on_tree_node_expanded(self, event: Tree.NodeExpanded[NodeData]) -> None:
        data = event.node.data
        if data is not None and data[0] == "ws":
            self._collapsed.discard(data[1])

    # ---- waiting windows --------------------------------------------------

    def _waiting_windows(self) -> list[tuple[str, str, int]]:
        """(workspace_id, window_id, waiting_since) for every waiting window
        across all workspaces, newest first."""
        out = [(ws_id, win.window_id, win.waiting_since)
               for ws_id, snapshot in self._windows.items()
               for win in snapshot.windows
               if win.waiting_since is not None]
        out.sort(key=lambda t: t[2], reverse=True)
        return out

    def _update_inspect(self) -> None:
        if self._inspect_timer is not None:
            self._inspect_timer.stop()
            self._inspect_timer = None
        ws_id = self.focused_workspace_id()
        if ws_id is None:
            self.query_one("#inspect-body", Static).update(
                Text("no workspaces", style=SUBTLE))
            return
        # Instant render: cached data if we have it, lightweight placeholder
        # otherwise. Either way the (1-2 s) HTTP fetch is debounced — it only
        # fires once the cursor has rested on the row for a moment, so flying
        # through rows doesn't hammer the inspect endpoint.
        cached = self._inspect_cache.get(ws_id)
        if cached is not None:
            self._render_inspect(ws_id, cached)
        else:
            self._render_inspect_placeholder(ws_id)
        self._inspect_timer = self.set_timer(
            0.3, lambda ws_id=ws_id: self._fetch_inspect(ws_id))

    def _row_attached(self, ws_id: str) -> int:
        for w in self._workspaces:
            if w.id == ws_id:
                return w.attached
        return 0

    def _render_inspect_placeholder(self, ws_id: str) -> None:
        """Instant stand-in while no cached inspect data exists yet."""
        liveness = "unknown"
        for w in self._workspaces:
            if w.id == ws_id:
                liveness = w.liveness
                break
        text = Text()
        text.append(f" {ws_id}\n", style=f"bold {ACCENT}")
        text.append(" ")
        text.append_text(state_cell(liveness, self._row_attached(ws_id)))
        text.append("\n")
        attached = self._row_attached(ws_id)
        if attached >= 1:
            text.append(" attached  ", style=SUBTLE)
            text.append(f"{attached} clients\n" if attached != 1 else "1 client\n")
        text.append("\n")
        text.append(" loading…", style=SUBTLE)
        self.query_one("#inspect-body", Static).update(text)

    def _render_inspect(self, ws_id: str, data: dict) -> None:
        text = Text()
        text.append(f" {ws_id}\n", style=f"bold {ACCENT}")
        text.append(" ")
        text.append_text(state_cell(data.get("liveness", "unknown"), self._row_attached(ws_id)))
        text.append("\n")
        attached = self._row_attached(ws_id)
        if attached >= 1:
            text.append(" attached  ", style=SUBTLE)
            text.append(f"{attached} clients\n" if attached != 1 else "1 client\n")
        text.append("\n")
        for label, value in inspect_lines(data):
            text.append(f" {label:<10}", style=SUBTLE)
            text.append(f"{value}\n")
        self.query_one("#inspect-body", Static).update(text)

    @work(exclusive=True, group="inspect")
    async def _fetch_inspect(self, ws_id: str) -> None:
        try:
            data = await self.app.client.inspect(ws_id)
        except CatalogError:
            # Keep a stale cached render if we have one; only show the
            # failure note when the row is still focused and has no cache.
            if (self.focused_workspace_id() == ws_id
                    and ws_id not in self._inspect_cache):
                self.query_one("#inspect-body", Static).update(
                    Text("inspect unavailable", style=SUBTLE))
            return
        self._inspect_cache[ws_id] = data
        # The cursor may have moved during the await — only re-render if
        # this workspace is still the focused one.
        if self.focused_workspace_id() != ws_id:
            return
        self._render_inspect(ws_id, data)

    # ---- status header ----------------------------------------------------

    def _update_header(self, connected: bool) -> None:
        """Rebuild the one-line status bar: host on the left, connection state on the right."""
        text = Text()
        text.append(" dvw", style=f"bold {ACCENT}")
        text.append(f" · {_CATALOG_HOST}", style=SUBTLE)
        if connected:
            text.append(" · connected", style=GREEN)
        else:
            text.append(" · unreachable", style=RED)
        waiting = len(self._waiting_windows())
        if waiting:
            text.append(f" · ⏸ {waiting} waiting", style=f"bold {ACCENT}")
        self.query_one("#status-header", Static).update(text)

    # ---- error banner -----------------------------------------------------

    def _show_error(self, message: str) -> None:
        banner = self.query_one("#error-banner", Static)
        banner.update(Text(f" ✗ {message}", style="bold"))
        banner.display = True
        self.query_one("#panes").add_class("dimmed")

    def _hide_error(self) -> None:
        self.query_one("#error-banner", Static).display = False
        self.query_one("#panes").remove_class("dimmed")

    # ---- filter -----------------------------------------------------------

    def action_filter(self) -> None:
        box = self.query_one("#filter-input", Input)
        box.display = True
        box.focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._commit_filter()

    def _commit_filter(self) -> None:
        box = self.query_one("#filter-input", Input)
        self._filter = box.value.strip()
        box.display = False
        self.query_one(WorkspaceTree).focus()
        self._render_tree()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._filter = event.value.strip()
        self._render_tree()

    # ---- actions ----------------------------------------------------------

    def action_refresh(self) -> None:
        self.refresh_data()

    def action_connect(self) -> None:
        # `enter` is a priority binding, so it fires even while the filter
        # input has focus — commit the filter there instead of connecting.
        if self.query_one("#filter-input", Input).has_focus:
            self._commit_filter()
            return
        # Enter must stay a *priority* binding: Tree binds enter to
        # select_cursor, which (auto_expand) would toggle the folder instead.
        # Because priority bindings dispatch before the focused widget sees
        # the key, the node's data kind is the only thing that decides where
        # Enter goes — same class of bug as the waiting-table fix in PR #36.
        self.activate_node(self.query_one(WorkspaceTree).cursor_node)

    def activate_node(self, node: TreeNode[NodeData] | None) -> None:
        """Enter / double-click on a tree node: window rows attach that
        window, workspace nodes ssh into the workspace.

        Reads the workspace id from `node.data[1]` in both branches — never
        the cursor — so activation always targets the node that was
        actually clicked/entered, not wherever the cursor happens to sit.
        """
        data = node.data if node is not None else None
        if data is None:
            return
        if data[0] == "win":
            self.app.do_attach(data[1], data[2])
            return
        ws_id = data[1]
        ws = next((w for w in self._workspaces if w.id == ws_id), None)
        self.app.do_connect(ws, "ssh")

    def action_stop(self) -> None:
        self.app.do_simple_action("stop", self.focused_workspace())

    def action_start(self) -> None:
        self.app.do_simple_action("start", self.focused_workspace())

    def action_rebuild(self) -> None:
        self.app.do_confirmed_action("rebuild", self.focused_workspace())

    def action_remove(self) -> None:
        self.app.do_confirmed_action("remove", self.focused_workspace())

    def action_new(self) -> None:
        self.app.do_new()

    def action_doctor(self) -> None:
        self.app.push_screen("doctor")

    def action_orphans(self) -> None:
        self.app.push_screen("orphans")

    def action_menu(self) -> None:
        self.app.open_context_menu()

    def action_attach_waiting(self) -> None:
        waiting = self._waiting_windows()
        if not waiting:
            self.notify("nothing waiting", title="dvw")
            return
        ws_id, window_id, _ = waiting[0]
        self.app.do_attach(ws_id, window_id)
