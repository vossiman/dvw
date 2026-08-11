"""Main screen: workspace table (left) + inspect pane (right)."""

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
from textual.widgets import DataTable, Footer, Input, Static

from ..client import CatalogError, WaitingWindow, Workspace
from ..render import ACCENT, GREEN, RED, SUBTLE, ide_cell, inspect_lines, state_cell

_CATALOG_HOST = os.environ.get("DVW_CATALOG_HOST", "vossisrv")


def _age(since: int) -> str:
    d = max(0, int(time.time()) - since)
    return f"{d // 3600}h" if d >= 3600 else f"{d // 60}m"


class WorkspaceTable(DataTable):
    """Left panel — one row per workspace, MRU order from the API.

    Single-click focuses a row. Double-click SSHs. Enter (MainScreen) also SSHs.

    Overrides DataTable._on_click so a second slow click on the already-focused
    row does *not* count as select — only event.chain == 2 (double-click).
    """

    async def _on_click(self, event: events.Click) -> None:
        from textual.coordinate import Coordinate

        self._set_hover_cursor(True)
        meta = event.style.meta
        if "row" not in meta or "column" not in meta:
            return
        row_index = meta["row"]
        column_index = meta["column"]
        if self.show_header and row_index == -1:
            # Preserve header-click behaviour from DataTable.
            await super()._on_click(event)
            return
        if self.show_row_labels and column_index == -1:
            await super()._on_click(event)
            return
        if not (self.show_cursor and self.cursor_type != "none"):
            return
        if self.cursor_type != "row" and meta.get("out_of_bounds", False):
            return

        self.cursor_coordinate = Coordinate(row_index, column_index)
        self._scroll_cursor_into_view(animate=True)
        event.stop()

        if event.chain != 2:
            return
        screen = self.screen
        if not isinstance(screen, MainScreen):
            return
        workspace = screen.focused_workspace()
        if workspace is not None:
            self.app.do_connect(workspace, "ssh")


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
        self._waiting: list[WaitingWindow] = []
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
                yield DataTable(id="waiting-table", cursor_type="row")
                yield WorkspaceTable(id="ws-table")
                yield Input(placeholder="filter…", id="filter-input")
            with VerticalScroll(id="right"):
                yield Static(" inspect", id="right-title")
                yield Static(id="inspect-body")
        yield Footer()

    def on_mount(self) -> None:
        self._update_header(connected=False)
        self.query_one("#error-banner", Static).display = False
        self.query_one("#filter-input", Input).display = False
        table = self.query_one(WorkspaceTable)
        table.cursor_type = "row"
        table.add_columns("workspace", "repo@branch", "ide", "state")
        waiting_table = self.query_one("#waiting-table", DataTable)
        waiting_table.add_columns("workspace", "window", "age")
        waiting_table.display = False
        self.set_interval(10.0, self.refresh_data)
        self.refresh_data()

    # ---- data -------------------------------------------------------------

    @work(exclusive=True)
    async def refresh_data(self) -> None:
        try:
            self._workspaces = await self.app.client.workspaces_with_status()
        except CatalogError as exc:
            self._show_error(f"catalog unreachable — {exc} — R to retry")
            self._update_header(connected=False)
            # Fail closed: don't leave stale waiting rows visible (or
            # attachable via `a`) once the workspace fetch itself failed.
            self._waiting = []
            self._render_waiting_table()
            return
        self._hide_error()
        self._update_header(connected=True)
        self._render_table()
        self._waiting = await self.app.client.waiting()
        self._render_waiting_table()

    def _render_waiting_table(self) -> None:
        table = self.query_one("#waiting-table", DataTable)
        table.clear()
        for w in self._waiting:
            table.add_row(
                Text(w.workspace_id, style=f"bold {ACCENT}"),
                Text(w.window_name, style=SUBTLE),
                _age(w.waiting_since),
            )
        table.display = bool(self._waiting)

    def _visible_workspaces(self) -> list[Workspace]:
        if not self._filter:
            return self._workspaces
        needle = self._filter.lower()
        return [w for w in self._workspaces
                if needle in w.id.lower() or needle in w.short_repo.lower()]

    def _render_table(self) -> None:
        table = self.query_one(WorkspaceTable)
        prev = self.focused_workspace_id()
        table.clear()
        for w in self._visible_workspaces():
            table.add_row(
                Text(w.id, style=f"bold {ACCENT}"),
                Text(f"{w.short_repo}@{w.branch}", style=SUBTLE),
                ide_cell(w.ide),
                state_cell(w.liveness, w.attached),
                key=w.id,
            )
        if prev is not None:
            try:
                row = table.get_row_index(prev)
                table.move_cursor(row=row)
            except Exception:
                pass
        self._update_inspect()

    def focused_workspace_id(self) -> str | None:
        table = self.query_one(WorkspaceTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        try:
            return str(table.coordinate_to_cell_key(
                table.cursor_coordinate).row_key.value)
        except Exception:
            return None

    def focused_workspace(self) -> Workspace | None:
        ws_id = self.focused_workspace_id()
        for w in self._workspaces:
            if w.id == ws_id:
                return w
        return None

    def on_data_table_row_highlighted(self, _event) -> None:
        self._update_inspect()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "waiting-table":
            return
        row_index = event.cursor_row
        if not (0 <= row_index < len(self._waiting)):
            return
        self.app.do_attach(self._waiting[row_index])

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
        self.query_one(WorkspaceTable).focus()
        self._render_table()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._filter = event.value.strip()
        self._render_table()

    # ---- actions ----------------------------------------------------------

    def action_refresh(self) -> None:
        self.refresh_data()

    def action_connect(self) -> None:
        # `enter` is a priority binding, so it fires even while the filter
        # input has focus — commit the filter there instead of connecting.
        if self.query_one("#filter-input", Input).has_focus:
            self._commit_filter()
            return
        # Priority bindings dispatch before the focused widget ever sees the
        # key, so if the waiting table has focus, Enter must attach *that*
        # row — not fall through to the workspace table's cursor row.
        waiting_table = self.query_one("#waiting-table", DataTable)
        # Guard on non-empty rather than just `.has_focus`: the waiting
        # table is the first focusable widget mounted, so it silently holds
        # initial app focus even while hidden/empty (no waiting rows) — that
        # shouldn't hijack Enter away from the workspace table.
        if waiting_table.has_focus and self._waiting:
            row_index = waiting_table.cursor_row
            if row_index is not None and 0 <= row_index < len(self._waiting):
                self.app.do_attach(self._waiting[row_index])
            return
        self.app.do_connect(self.focused_workspace(), "ssh")

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
        if not self._waiting:
            self.notify("nothing waiting", title="dvw")
            return
        self.app.do_attach(self._waiting[0])
