"""Context menu (x) — every action for the focused workspace, lazydocker-style."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import OptionList, Static
from textual.widgets.option_list import Option


MENU_ITEMS = [
    ("connect", "enter  connect"),
    ("stop", "s      stop"),
    ("start", "S      start"),
    ("rebuild", "r      rebuild"),
    ("remove", "X      remove"),
    ("new", "n      new workspace"),
    ("doctor", "d      doctor"),
    ("orphans", "o      orphans"),
]


class MenuScreen(ModalScreen[str | None]):
    BINDINGS = [Binding("escape", "dismiss_menu", "close")]

    def __init__(self, workspace_id: str | None) -> None:
        super().__init__()
        self._workspace_id = workspace_id

    def compose(self) -> ComposeResult:
        with Vertical(id="menu-box"):
            title = self._workspace_id or "—"
            yield Static(f" {title}", id="menu-title")
            yield OptionList(
                *[Option(label, id=action) for action, label in MENU_ITEMS],
                id="menu-list",
            )

    def action_dismiss_menu(self) -> None:
        self.dismiss(None)

    def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ) -> None:
        self.dismiss(event.option.id)
