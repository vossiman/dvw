"""Main screen: workspace table (left) + inspect pane (right)."""

from __future__ import annotations

import os

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import Screen
from textual.timer import Timer
from textual.widgets import DataTable, Footer, Input, Static

from ..client import CatalogError, Workspace
from ..render import ACCENT, GREEN, RED, SUBTLE, ide_cell, inspect_lines, liveness_cell

_CATALOG_HOST = os.environ.get("DVW_CATALOG_HOST", "vossisrv")


class WorkspaceTable(DataTable):
    """Left panel — one row per workspace, MRU order from the API."""


class MainScreen(Screen):
    BINDINGS = [
        Binding("enter", "connect", "connect", priority=True),
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
            return
        self._hide_error()
        self._update_header(connected=True)
        self._render_table()

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
                liveness_cell(w.liveness),
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
        text.append_text(liveness_cell(liveness))
        text.append("\n\n")
        text.append(" loading…", style=SUBTLE)
        self.query_one("#inspect-body", Static).update(text)

    def _render_inspect(self, ws_id: str, data: dict) -> None:
        text = Text()
        text.append(f" {ws_id}\n", style=f"bold {ACCENT}")
        text.append(" ")
        text.append_text(liveness_cell(data.get("liveness", "unknown")))
        text.append("\n\n")
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
        self.app.do_connect(self.focused_workspace())

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
