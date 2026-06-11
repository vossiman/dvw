"""Orphans screen — devpod-labelled containers not in the catalog.

Removal stays guarded: confirm modal, then a SUSPENDED `ssh <host> docker
rm -f <name>` so the user sees exactly what runs. Mirrors the bash stance
that destructive ops are explicit and visible."""

from __future__ import annotations

import os

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Static

from ..client import CatalogError
from ..render import ACCENT, GREY, RED, SUBTLE, YELLOW
from .confirm import ConfirmScreen

_MOUNT_STYLE = {"alive": YELLOW, "deleted": RED, "nomount": GREY}


class OrphansScreen(Screen):
    BINDINGS = [
        Binding("escape", "app.pop_screen", "back"),
        Binding("q", "app.pop_screen", "back"),
        Binding("X", "remove", "remove"),
        Binding("R", "refresh", "refresh"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._orphans: list[dict] = []

    def compose(self) -> ComposeResult:
        yield Static(" ⚠ orphan containers — may contain data, verify before removing",
                     id="orphans-title")
        yield DataTable(id="orphans-table")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#orphans-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("container", "workspace", "state", "mount")
        self.refresh_orphans()

    def action_refresh(self) -> None:
        self.refresh_orphans()

    @work(exclusive=True)
    async def refresh_orphans(self) -> None:
        table = self.query_one("#orphans-table", DataTable)
        try:
            self._orphans = await self.app.client.orphans()
        except CatalogError as exc:
            self.notify(f"orphans unavailable: {exc}", severity="error")
            return
        table.clear()
        for o in self._orphans:
            name = o.get("container_name") or o.get("container_id", "?")
            mount = o.get("mount_status", "?")
            table.add_row(
                Text(name, style=f"bold {ACCENT}"),
                Text(o.get("workspace_id") or "—", style=SUBTLE),
                Text(o.get("state") or "?", style=SUBTLE),
                Text(mount, style=_MOUNT_STYLE.get(mount, GREY)),
                key=name,
            )
        if not self._orphans:
            self.notify("no orphan containers", title="dvw")

    def _focused_orphan(self) -> dict | None:
        table = self.query_one("#orphans-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        key = str(table.coordinate_to_cell_key(
            table.cursor_coordinate).row_key.value)
        for o in self._orphans:
            if (o.get("container_name") or o.get("container_id")) == key:
                return o
        return None

    def action_remove(self) -> None:
        orphan = self._focused_orphan()
        if orphan is None:
            return
        name = orphan.get("container_name") or orphan.get("container_id")
        host = os.environ.get("DVW_CATALOG_HOST", "vossisrv")
        message = (f"docker rm -f {name} on {host}?\n\n"
                   "Orphans may hold uncommitted work — audit first "
                   "(dvw menu → audit) if unsure.")

        def on_result(confirmed: bool | None) -> None:
            if confirmed:
                self.app._run_suspended(["ssh", host, "docker", "rm", "-f", name])
                self.refresh_orphans()

        self.app.push_screen(ConfirmScreen(message, danger=True), on_result)
