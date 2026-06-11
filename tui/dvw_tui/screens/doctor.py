"""Doctor screen — runs `dvw doctor` captured and renders the ANSI report.

The bash doctor emits ANSI colors unconditionally and skips its interactive
prompts when stdin isn't a tty, so a captured run is safe and complete."""

from __future__ import annotations

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, RichLog, Static
from textual.worker import get_current_worker

from .. import actions
from ..render import SUBTLE


class DoctorScreen(Screen):
    BINDINGS = [
        Binding("escape", "app.pop_screen", "back"),
        Binding("q", "app.pop_screen", "back"),
        Binding("r", "rerun", "re-run"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._last_output = ""

    def compose(self) -> ComposeResult:
        yield Static(" ⚕ dvw doctor", id="doctor-title")
        yield RichLog(id="doctor-log", wrap=True)
        yield Footer()

    def on_mount(self) -> None:
        self._run_doctor()

    def action_rerun(self) -> None:
        self._run_doctor()

    @work(exclusive=True, thread=True)
    def _run_doctor(self) -> None:
        worker = get_current_worker()
        log = self.query_one("#doctor-log", RichLog)
        self.app.call_from_thread(log.clear)
        self.app.call_from_thread(
            log.write, Text("running checks…", style=SUBTLE))
        result = actions.run_captured(actions.doctor())
        if worker.is_cancelled:
            return
        report = Text.from_ansi(result.output)

        def render() -> None:
            self._last_output = result.output
            log.clear()
            log.write(report)
            if not result.ok:
                log.write(Text(f"\n(doctor exited {result.returncode})",
                               style="bold #bf616a"))

        self.app.call_from_thread(render)
