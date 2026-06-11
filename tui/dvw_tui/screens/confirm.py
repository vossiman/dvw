"""Yes/no modal. Dismisses with True/False; y/n keys or buttons."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Static


class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [
        Binding("y", "yes", "yes"),
        Binding("n", "no", "no"),
        Binding("escape", "no", "cancel"),
    ]

    def __init__(self, message: str, danger: bool = False) -> None:
        super().__init__()
        self._message = message
        self._danger = danger

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box", classes="danger" if self._danger else ""):
            yield Static(self._message, id="confirm-message")
            with Horizontal(id="confirm-buttons"):
                yield Button("yes (y)", id="confirm-yes",
                             variant="error" if self._danger else "primary")
                yield Button("no (n)", id="confirm-no")

    def action_yes(self) -> None:
        self.dismiss(True)

    def action_no(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-yes")
