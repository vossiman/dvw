"""App entry point: wires client, screens, and shared action plumbing.

Action methods live on the app (not the screen) because the context menu
and the main screen both invoke them.
"""

from __future__ import annotations

import os
import re

from textual.app import App

from . import actions
from .client import CatalogClient, Workspace
from .palette import TOKYO, build_theme
from .screens.confirm import ConfirmScreen
from .screens.doctor import DoctorScreen
from .screens.main import MainScreen
from .screens.menu import MenuScreen
from .screens.orphans import OrphansScreen
from .screens.wizard import WizardResult, WizardScreen


class DvwApp(App):
    """dvw workspace control center."""

    CSS_PATH = "theme.tcss"
    TITLE = "dvw"
    SCREENS = {"doctor": DoctorScreen, "orphans": OrphansScreen}

    def __init__(self, client: object | None = None) -> None:
        super().__init__()
        self.client = client or CatalogClient()
        # Registered (not get_css_variables()-overridden) so Textual
        # regenerates the derived variables ($accent-muted, $text-accent,
        # ...) from our roles instead of leaving them on its default hue.
        # Done in __init__, before the first compose/paint, so the app
        # never renders a frame in Textual's built-in theme.
        theme = build_theme(palette=TOKYO)
        self.register_theme(theme)
        self.theme = theme.name

    def get_default_screen(self) -> MainScreen:
        # MainScreen is the base of the screen stack (Textual >= 1.x queries
        # the default screen from App.query_*, so pushing in on_mount would
        # leave a blank default screen underneath).
        return MainScreen()

    def on_mount(self) -> None:
        # `dvw new` (bare, TUI available) lands directly in the wizard.
        if os.environ.get("DVW_TUI_START") == "new":
            self.do_new()

    async def on_unmount(self) -> None:
        await self.client.aclose()

    # ---- execution helpers --------------------------------------------------

    def _run_suspended(self, argv: list[str], pause_on_fail: bool = True) -> int:
        """Hand the real terminal to an interactive bash dvw command (confirm
        prompts, progress output, ssh sessions). On failure, hold the
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

    def do_connect(self, workspace: Workspace | None, mode: str) -> None:
        """Connect immediately in the given mode (ssh / cursor / both).

        Enter and double-click always pass mode=\"ssh\". Cursor and both are
        only offered via the context menu (or CLI flags).
        """
        if workspace is None:
            return
        argv = actions.connect(workspace.id, mode)
        if actions.connect_mode(mode) == "background":
            actions.run_background(argv)
            self.notify(f"connecting {workspace.id} (cursor)…", title="dvw")
        else:
            self._run_suspended(argv)

    def do_attach(self, workspace_id: str | None, window_id: str | None) -> None:
        """Attach to a specific tmux window via the bash ssh path. Window ids
        come from the catalog; re-validate before argv (defense in depth —
        _dvw_ssh_session validates again)."""
        if not workspace_id or not window_id:
            return
        if not re.fullmatch(r"@[0-9]+", window_id):
            self.notify(f"bad window id from catalog: {window_id!r}",
                        title="dvw", severity="error")
            return
        self._run_suspended(actions.connect(workspace_id, "ssh",
                                            window=window_id))

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
        def on_result(result: WizardResult | None) -> None:
            if result is None:
                return
            self._run_suspended(actions.new_create(
                result.repo, result.branch, result.name, result.ide,
                init_empty=result.init_empty,
                seed_devcontainer=result.seed_devcontainer))

        self.push_screen(WizardScreen(), on_result)

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
            if action in ("ssh", "cursor", "both"):
                self.do_connect(workspace, action)
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
