"""App entry point: wires client, screens, and shared action plumbing.

Action methods live on the app (not the screen) because the context menu
(Task 8) and the main screen both invoke them. Bodies that need confirm
modals / suspend land in Task 6 — here they are minimal placeholders that
only cover what's testable now.
"""

from __future__ import annotations

from textual.app import App

from .client import CatalogClient, Workspace
from .screens.main import MainScreen


class DvwApp(App):
    """dvw workspace control center."""

    CSS_PATH = "theme.tcss"
    TITLE = "dvw"

    def __init__(self, client: object | None = None) -> None:
        super().__init__()
        self.client = client or CatalogClient()

    def get_default_screen(self) -> MainScreen:
        # MainScreen is the base of the screen stack (Textual >= 1.x queries
        # the default screen from App.query_*, so pushing in on_mount would
        # leave a blank default screen underneath).
        return MainScreen()

    async def on_unmount(self) -> None:
        await self.client.aclose()

    # ---- action plumbing (full implementations in Task 6) ------------------

    def do_connect(self, workspace: Workspace | None) -> None:
        pass

    def do_simple_action(self, name: str, workspace: Workspace | None) -> None:
        pass

    def do_confirmed_action(self, name: str, workspace: Workspace | None) -> None:
        pass

    def do_new(self) -> None:
        pass

    def open_context_menu(self) -> None:
        pass


def main() -> None:
    DvwApp().run()


if __name__ == "__main__":
    main()
