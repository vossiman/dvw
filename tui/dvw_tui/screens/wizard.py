"""New-workspace wizard. Gathers repo/branch/name; all *doing* stays in
bash — the app runs the flag-form `dvw new … --yes` suspended afterwards.

Steps: repo (catalog list + free input) -> branches (thread worker) ->
devcontainer check (thread worker) -> name -> summary confirm.

No IDE step: every workspace is created `ssh`; Cursor is a per-connect
choice from the main menu, not a property of the workspace.

Two rules govern the workers: the thread body never touches widgets (UI
mutation is marshalled with `App.call_from_thread`), and nothing may run
after the screen has been dismissed (the `_done` latch is checked on both
sides of the handoff).
"""

from __future__ import annotations

from dataclasses import dataclass

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.css.query import NoMatches
from textual.screen import ModalScreen
from textual.widgets import Input, LoadingIndicator, OptionList, Static
from textual.widgets.option_list import Option

from .. import actions
from ..wizard_names import DEVPOD_NAME_MAX, _sanitize, default_workspace_name
from .confirm import ConfirmScreen

NEW_REPO_OPTION = "+ enter new…"
NEW_REPO_ID = "__new__"


@dataclass
class WizardResult:
    repo: str
    branch: str
    name: str
    init_empty: bool = False
    seed_devcontainer: bool = False


class WizardScreen(ModalScreen["WizardResult | None"]):
    """Modal step machine. Dismisses with a WizardResult, or None on abort."""

    # Priority: a focused Input swallows plain screen bindings (same lesson
    # as the waiting-row enter fix — see MainScreen's priority bindings).
    BINDINGS = [Binding("escape", "abort", "cancel", priority=True)]

    def __init__(self) -> None:
        super().__init__()
        self._repo = ""
        self._branch = ""
        self._name = ""
        self._init_empty = False
        self._seed = False
        self._done = False

    def compose(self) -> ComposeResult:
        with Vertical(id="wizard-box"):
            yield Static("new workspace", id="wizard-title")
            yield Vertical(id="wizard-step")

    async def on_mount(self) -> None:
        await self._step_repo()

    # ---- dismissal ---------------------------------------------------------

    def action_abort(self) -> None:
        self._finish(None)

    def _finish(self, result: WizardResult | None) -> None:
        """Single exit point — latched, so a late worker callback or a second
        key press can never dismiss twice (the second dismiss would pop an
        unrelated screen)."""
        if self._done:
            return
        self._done = True
        self.dismiss(result)

    # ---- widget plumbing ---------------------------------------------------

    async def _swap(self, *widgets) -> None:
        """Replace the step body. The last widget gets focus (OptionLists
        also get their first row highlighted so enter works immediately)."""
        if self._done:
            return
        try:
            step = self.query_one("#wizard-step", Vertical)
        except NoMatches:  # screen torn down under us
            return
        await step.remove_children()
        await step.mount(*widgets)
        last = widgets[-1]
        if isinstance(last, OptionList) and last.options:
            last.highlighted = 0
        last.focus()

    async def _show_busy(self, message: str) -> None:
        await self._swap(Static(message, classes="wizard-label"),
                         LoadingIndicator())

    def _later(self, callback) -> None:
        """Run an async step from a sync callback (confirm results, worker
        handoffs) on the screen's own message pump."""
        if not self._done:
            self.call_later(callback)

    # ---- step: repo --------------------------------------------------------

    async def _step_repo(self) -> None:
        try:
            repos = await self.app.client.repos()
        except Exception:
            repos = []
            self.app.notify("catalog unreachable — enter a repo URL manually",
                            title="dvw", severity="warning")
        options = [Option(NEW_REPO_OPTION, id=NEW_REPO_ID)]
        options += [Option(repo, id=repo) for repo in repos]
        await self._swap(Static("repo", classes="wizard-label"),
                         OptionList(*options, id="wizard-repo-list"))

    async def _step_repo_input(self) -> None:
        await self._swap(
            Static("repo (url, owner/name, or gh:owner/name)",
                   classes="wizard-label"),
            Input(placeholder="git@github.com:owner/repo.git",
                  id="wizard-repo-input"))

    async def _repo_chosen(self, repo: str) -> None:
        self._repo = repo
        await self._show_busy(f"fetching branches for {repo}…")
        self._start_worker(actions.new_list_branches(repo), self._branches_done)

    # ---- workers -----------------------------------------------------------

    def _start_worker(self, argv: list[str], done) -> None:
        """Run a blocking `dvw new …` probe off the event loop and marshal the
        result back. `done` runs on the message pump, never in the thread."""

        def work() -> None:
            # Split capture: these probes' stdout is a contract (line 1 = the
            # resolved URL); stderr carries ui_progress markers and chatter.
            result = actions.run_captured_split(argv)
            if self._done:
                return
            try:
                self.app.call_from_thread(done, result)
            except RuntimeError:
                # App shut down (or worker cancelled) while we were running.
                pass

        self.run_worker(work, thread=True, group="wizard-probe",
                        exclusive=True)

    def _branches_done(self, result: actions.ActionResult) -> None:
        if self._done:
            return
        lines = [line for line in result.output.splitlines() if line.strip()]
        resolved = lines[0].strip() if lines else self._repo

        if result.returncode == 0:
            self._repo = resolved
            branches = [line.strip() for line in lines[1:]]
            if not branches:
                self.notify("no branches reported for this repo",
                            title="dvw", severity="error")
                self._finish(None)
                return
            self._later(lambda: self._step_branch(branches))
            return

        if result.returncode == 3:
            self._repo = resolved
            self._later(self._ask_init_empty)
            return

        self.notify(f"couldn't reach {self._repo} — check the URL and your "
                    "git credentials", title="dvw", severity="error")
        self._finish(None)

    async def _step_branch(self, branches: list[str]) -> None:
        await self._swap(
            Static("branch", classes="wizard-label"),
            OptionList(*[Option(b, id=b) for b in branches],
                       id="wizard-branch-list"))

    def _ask_init_empty(self) -> None:
        def on_result(confirmed: bool | None) -> None:
            if confirmed:
                self._init_empty = True
                self._branch = "main"
                # Nothing to inspect on a repo we are about to create the
                # first commit in — the blueprint devcontainer ships with it.
                self._later(self._step_name)
            else:
                self._finish(None)

        self.app.push_screen(
            ConfirmScreen("Repo is empty — create an initial commit on 'main' "
                          "(with the blueprint devcontainer.json)?"),
            on_result)

    async def _branch_chosen(self, branch: str) -> None:
        self._branch = branch
        await self._show_busy(f"checking devcontainer.json on {branch}…")
        self._start_worker(
            actions.new_check_devcontainer(self._repo, branch),
            self._devcontainer_done)

    def _devcontainer_done(self, result: actions.ActionResult) -> None:
        if self._done:
            return
        if result.returncode == 0:
            self._later(self._step_name)
            return
        if result.returncode == 1:
            def on_result(confirmed: bool | None) -> None:
                if confirmed:
                    self._seed = True
                self._later(self._step_name)

            self.app.push_screen(
                ConfirmScreen(f"No devcontainer.json on '{self._branch}' — "
                              "commit the blueprint one and push?"),
                on_result)
            return
        self.notify(f"couldn't inspect '{self._branch}' — continuing",
                    title="dvw", severity="warning")
        self._later(self._step_name)

    # ---- step: name --------------------------------------------------------

    async def _step_name(self) -> None:
        await self._swap(
            Static("workspace name", classes="wizard-label"),
            Input(value=default_workspace_name(self._repo, self._branch),
                  max_length=DEVPOD_NAME_MAX, id="wizard-name-input"))

    # ---- step: summary -----------------------------------------------------

    def _step_summary(self) -> None:
        def on_result(confirmed: bool | None) -> None:
            if confirmed:
                self._finish(WizardResult(
                    repo=self._repo, branch=self._branch, name=self._name,
                    init_empty=self._init_empty,
                    seed_devcontainer=self._seed))
            else:
                self._later(self._step_name)

        self.app.push_screen(
            ConfirmScreen(f"Create {self._name} from {self._repo}"
                          f"@{self._branch}?"),
            on_result)

    # ---- events ------------------------------------------------------------

    async def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ) -> None:
        list_id = event.option_list.id
        value = event.option.id or str(event.option.prompt)
        if list_id == "wizard-repo-list":
            if value == NEW_REPO_ID:
                await self._step_repo_input()
            else:
                await self._repo_chosen(value)
        elif list_id == "wizard-branch-list":
            await self._branch_chosen(value)

    async def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "wizard-repo-input":
            repo = event.value.strip()
            if not repo:
                self.notify("enter a repo", title="dvw", severity="warning")
                return
            await self._repo_chosen(repo)
        elif event.input.id == "wizard-name-input":
            name = _sanitize(event.value)[:DEVPOD_NAME_MAX].rstrip("-")
            if not name:
                self.notify("name must contain a letter or digit",
                            title="dvw", severity="warning")
                return
            self._name = name
            self._step_summary()
