"""App entry point: wires client, screens, and shared action plumbing.

Action methods live on the app (not the screen) because the context menu
(Task 8) and the main screen both invoke them.
"""

from __future__ import annotations

from textual.app import App

from . import actions
from .client import CatalogClient, Workspace
from .screens.confirm import ConfirmScreen
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

    # ---- execution helpers --------------------------------------------------

    def _run_suspended(self, argv: list[str], pause_on_fail: bool = True) -> None:
        """Hand the real terminal to an interactive bash dvw command (gum
        confirms, progress output, ssh sessions). On failure, hold the
        terminal so the user can read the error before the alt screen
        swallows it."""
        with self.suspend():
            try:
                rc = actions.run_interactive(argv)
            except OSError as exc:
                # e.g. DVW_BIN missing — don't let the TUI crash mid-suspend.
                print(f"\n[dvw tui] failed to run `{' '.join(argv)}`: {exc}")
                rc = 127
            if rc != 0 and pause_on_fail:
                input(f"\n[dvw tui] `{' '.join(argv)}` exited {rc} — "
                      "press enter to return ")
        self._refresh_main()

    def _refresh_main(self) -> None:
        for screen in self.screen_stack:
            if isinstance(screen, MainScreen):
                screen.refresh_data()

    # ---- actions ------------------------------------------------------------

    def do_connect(self, workspace: Workspace | None) -> None:
        if workspace is None:
            return
        argv = actions.connect(workspace.id)
        if actions.connect_mode(workspace.ide) == "background":
            actions.run_background(argv)
            self.notify(f"connecting {workspace.id} ({workspace.ide})…",
                        title="dvw")
        else:
            self._run_suspended(argv)

    def do_simple_action(self, name: str, workspace: Workspace | None) -> None:
        if workspace is None:
            return
        builder = {"stop": actions.stop, "start": actions.start}[name]
        self._run_suspended(builder(workspace.id))
        self.notify(f"{name}: {workspace.id}", title="dvw")

    def do_confirmed_action(self, name: str, workspace: Workspace | None) -> None:
        if workspace is None:
            return
        prompts = {
            "rebuild": (f"Rebuild {workspace.id}? The container is recreated "
                        "from the current devcontainer config.", False),
            "remove": (f"Remove {workspace.id}? This deletes the workspace "
                       "container.", True),
        }
        builders = {"rebuild": actions.rebuild, "remove": actions.remove}
        message, danger = prompts[name]

        def on_result(confirmed: bool | None) -> None:
            if confirmed:
                self._run_suspended(builders[name](workspace.id))

        self.push_screen(ConfirmScreen(message, danger=danger), on_result)

    def do_new(self) -> None:
        self._run_suspended(actions.new())

    def open_context_menu(self) -> None:
        pass  # Task 8


def main() -> None:
    DvwApp().run()


if __name__ == "__main__":
    main()
