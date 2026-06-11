"""Connect-mode chooser — replaces the bash gum chooser so background
connects (GUI IDEs, no TTY) don't silently cancel."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import OptionList, Static
from textual.widgets.option_list import Option


CONNECT_MODES = [
    ("ssh", "ssh     SSH (terminal + tmux)"),
    ("cursor", "cursor  Cursor (GUI)"),
    ("both", "both    Both (Cursor + SSH/tmux)"),
]


class ConnectScreen(ModalScreen[str | None]):
    BINDINGS = [Binding("escape", "dismiss_connect", "close")]

    def __init__(self, workspace_id: str, default_ide: str) -> None:
        super().__init__()
        self._workspace_id = workspace_id
        self._default_ide = default_ide

    def compose(self) -> ComposeResult:
        with Vertical(id="connect-box"):
            yield Static(f" connect {self._workspace_id} via", id="connect-title")
            yield OptionList(
                *[Option(label, id=mode) for mode, label in CONNECT_MODES],
                id="connect-list",
            )

    def on_mount(self) -> None:
        # Preselect from the workspace's catalog ide: cursor → cursor,
        # anything else → ssh (mirrors bash _connect_choose_mode).
        target = "cursor" if self._default_ide == "cursor" else "ssh"
        index = next(i for i, (mode, _label) in enumerate(CONNECT_MODES)
                     if mode == target)
        self.query_one("#connect-list", OptionList).highlighted = index

    def action_dismiss_connect(self) -> None:
        self.dismiss(None)

    def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ) -> None:
        self.dismiss(event.option.id)
