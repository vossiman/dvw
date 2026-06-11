"""Main screen: workspace table (left) + inspect pane (right)."""

from __future__ import annotations

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Input, Static

from ..client import CatalogError, Workspace
from ..render import ACCENT, SUBTLE, ide_cell, inspect_lines, liveness_cell


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
        Binding("q", "quit", "quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._workspaces: list[Workspace] = []
        self._filter = ""

    # ---- layout -----------------------------------------------------------

    def compose(self) -> ComposeResult:
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
            return
        self._hide_error()
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
        ws_id = self.focused_workspace_id()
        if ws_id is None:
            self.query_one("#inspect-body", Static).update(
                Text("no workspaces", style=SUBTLE))
            return
        self._fetch_inspect(ws_id)

    @work(exclusive=True, group="inspect")
    async def _fetch_inspect(self, ws_id: str) -> None:
        body = self.query_one("#inspect-body", Static)
        try:
            data = await self.app.client.inspect(ws_id)
        except CatalogError:
            body.update(Text("inspect unavailable", style=SUBTLE))
            return
        text = Text()
        text.append(f" {ws_id}\n", style=f"bold {ACCENT}")
        text.append(" ")
        text.append_text(liveness_cell(data.get("liveness", "unknown")))
        text.append("\n\n")
        for label, value in inspect_lines(data):
            text.append(f" {label:<10}", style=SUBTLE)
            text.append(f"{value}\n")
        body.update(text)

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

    # ---- actions (wired fully in Task 6) -----------------------------------

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
