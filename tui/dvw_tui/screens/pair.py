"""Pair screen — runs `paseo daemon pair` in the pod over ssh; shows QR + offer link.

The QR is half-block ANSI text — RichLog + Text.from_ansi render it as-is.
The same QR pairs every device (offer derives from the daemon keypair).
"""

from __future__ import annotations

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, RichLog, Static
from textual.worker import get_current_worker

from .. import actions

HINT = "pair manually: dvw connect <id>, then: paseo daemon pair"


class PairScreen(Screen):
    """Runs `paseo daemon pair` in the pod over ssh; shows QR + offer link.

    The QR is half-block ANSI text — RichLog + Text.from_ansi render it as-is.
    The same QR pairs every device (offer derives from the daemon keypair).
    """

    BINDINGS = [
        Binding("escape", "app.pop_screen", "back"),
        Binding("q", "app.pop_screen", "back"),
        Binding("r", "rerun", "re-run"),
    ]

    def __init__(self, workspace_id: str) -> None:
        super().__init__()
        self._workspace_id = workspace_id
        self.last_result = None

    def compose(self) -> ComposeResult:
        yield Static(f" ⛓ pair remote (paseo) — {self._workspace_id}", id="pair-title")
        yield RichLog(id="pair-log", wrap=False)
        yield Footer()

    def on_mount(self) -> None:
        self._run_pair()

    def action_rerun(self) -> None:
        self._run_pair()

    @work(exclusive=True, thread=True)
    def _run_pair(self) -> None:
        worker = get_current_worker()
        log = self.query_one("#pair-log", RichLog)
        self.app.call_from_thread(log.clear)
        result = actions.run_captured(actions.pair_paseo(self._workspace_id))
        if worker.is_cancelled:
            return
        self.last_result = result
        body = Text.from_ansi(result.output)

        def render() -> None:
            log.clear()
            log.write(body)
            if not result.ok:
                log.write(Text(f"\npairing unavailable (rc={result.returncode}) — {HINT}"))
            else:
                log.write(Text("\nscan with the paseo app — same QR for every device"))

        self.app.call_from_thread(render)
