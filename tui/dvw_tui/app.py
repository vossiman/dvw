"""App entry point: wires client, screens, and shared action plumbing.

Action methods live on the app (not the screen) because the context menu
and the main screen both invoke them.
"""

from __future__ import annotations

from textual.app import App

from . import actions
from .client import CatalogClient, Workspace
from .screens.confirm import ConfirmScreen
from .screens.connect import ConnectScreen
from .screens.doctor import DoctorScreen
from .screens.main import MainScreen
from .screens.menu import MenuScreen
from .screens.orphans import OrphansScreen


class DvwApp(App):
    """dvw workspace control center."""

    CSS_PATH = "theme.tcss"
    TITLE = "dvw"
    SCREENS = {"doctor": DoctorScreen, "orphans": OrphansScreen}

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

    def _run_suspended(self, argv: list[str], pause_on_fail: bool = True) -> int:
        """Hand the real terminal to an interactive bash dvw command (gum
        confirms, progress output, ssh sessions). On failure, hold the
        terminal so the user can read the error before the alt screen
        swallows it.

        Returns the subprocess exit code (127 = OSError, 130 = Ctrl-C).

        IMPORTANT: no exception must escape the suspend() context manager —
        an unhandled exception would leave the terminal unresumed and the TUI
        in a broken state.
        """
        with self.suspend():
            try:
                rc = actions.run_interactive(argv)
            except KeyboardInterrupt:
                # Ctrl-C during the subprocess — treat as SIGINT exit code 130.
                # Do NOT re-raise; fall through so suspend() exits cleanly and
                # the TUI resumes with the terminal in a consistent state.
                rc = 130
            except OSError as exc:
                # e.g. DVW_BIN missing — don't let the TUI crash mid-suspend.
                print(f"\n[dvw tui] failed to run `{' '.join(argv)}`: {exc}")
                rc = 127
            if rc != 0 and pause_on_fail:
                try:
                    input(f"\n[dvw tui] `{' '.join(argv)}` exited {rc} — "
                          "press enter to return ")
                except KeyboardInterrupt:
                    # Ctrl-C during the pause prompt — just continue back to TUI.
                    pass
        self._refresh_main()
        return rc

    def _refresh_main(self) -> None:
        for screen in self.screen_stack:
            if isinstance(screen, MainScreen):
                screen.refresh_data()

    # ---- actions ------------------------------------------------------------

    def do_connect(self, workspace: Workspace | None) -> None:
        if workspace is None:
            return

        def on_mode(mode: str | None) -> None:
            if mode is None:
                return
            argv = actions.connect(workspace.id, mode)
            if actions.connect_mode(mode) == "background":
                actions.run_background(argv)
                self.notify(f"connecting {workspace.id} (cursor)…",
                            title="dvw")
            else:
                self._run_suspended(argv)

        self.push_screen(ConnectScreen(workspace.id, workspace.ide), on_mode)

    def do_simple_action(self, name: str, workspace: Workspace | None) -> None:
        if workspace is None:
            return
        builder = {"stop": actions.stop, "start": actions.start}[name]
        rc = self._run_suspended(builder(workspace.id))
        if rc == 0:
            self.notify(f"{name}: {workspace.id}", title="dvw")
        else:
            self.notify(
                f"{name} {workspace.id} failed (rc={rc}) — see output",
                title="dvw",
                severity="error",
            )

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

    def do_remove_orphan(self, host: str, container_name: str) -> None:
        """Guarded orphan removal — suspended so the user sees exactly
        what runs on the provider."""
        self._run_suspended(["ssh", host, "docker", "rm", "-f", container_name])

    def open_context_menu(self) -> None:
        main = self.screen
        if not isinstance(main, MainScreen):
            return
        workspace = main.focused_workspace()

        def on_result(action: str | None) -> None:
            if action is None:
                return
            if action == "connect":
                self.do_connect(workspace)
            elif action in ("stop", "start"):
                self.do_simple_action(action, workspace)
            elif action in ("rebuild", "remove"):
                self.do_confirmed_action(action, workspace)
            elif action == "new":
                self.do_new()
            elif action in ("doctor", "orphans"):
                self.push_screen(action)

        self.push_screen(
            MenuScreen(workspace.id if workspace else None), on_result)


def main() -> None:
    DvwApp().run()


if __name__ == "__main__":
    main()
