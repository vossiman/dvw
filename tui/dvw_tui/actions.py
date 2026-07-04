"""Mutation dispatch: the TUI never orchestrates devpod itself — every
action shells out to the battle-tested bash `dvw` paths.

Two execution styles, chosen by the app layer:
  - suspend: Textual suspends, the command runs interactively in the real
    terminal (gum confirms, progress output, ssh sessions all work).
  - background: fire-and-forget Popen for GUI IDE connects.
  - captured: run quietly, collect output (doctor report rendering).
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass

def dvw_bin() -> str:
    return os.environ.get("DVW_BIN", "dvw")


def stop(workspace_id: str) -> list[str]:
    return [dvw_bin(), "stop", workspace_id]


def start(workspace_id: str) -> list[str]:
    return [dvw_bin(), "start", workspace_id]


def rebuild(workspace_id: str) -> list[str]:
    return [dvw_bin(), "rebuild", workspace_id]


def remove(workspace_id: str) -> list[str]:
    return [dvw_bin(), "rm", workspace_id]


def connect(workspace_id: str, mode: str | None = None) -> list[str]:
    """Connect argv. With an explicit mode ("ssh"/"cursor"/"both") the bash
    side skips its gum chooser (--ssh/--cursor/--both)."""
    if mode is None:
        return [dvw_bin(), workspace_id]
    return [dvw_bin(), workspace_id, f"--{mode}"]


def new() -> list[str]:
    return [dvw_bin(), "new"]


def doctor() -> list[str]:
    return [dvw_bin(), "doctor"]


def connect_mode(mode: str) -> str:
    """Map a chosen connect MODE ("ssh"/"cursor"/"both") to an execution
    style: 'background' keeps the TUI up (cursor opens out-of-terminal);
    'suspend' hands over the terminal (ssh, both, and anything
    unrecognized — safe default, since "both" includes an ssh session)."""
    return "background" if mode == "cursor" else "suspend"


@dataclass
class ActionResult:
    ok: bool
    returncode: int
    output: str


def run_captured(argv: list[str]) -> ActionResult:
    """Run quietly, merge stdout+stderr (the bash side interleaves them)."""
    try:
        proc = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, stdin=subprocess.DEVNULL,
        )
    except OSError as exc:
        return ActionResult(ok=False, returncode=127, output=str(exc))
    return ActionResult(ok=proc.returncode == 0, returncode=proc.returncode,
                        output=proc.stdout or "")


def run_background(argv: list[str]) -> None:
    """Fire-and-forget (GUI IDE connect). Output discarded; the IDE window
    is the feedback."""
    subprocess.Popen(
        argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )


def run_interactive(argv: list[str]) -> int:
    """Run attached to the real terminal. The app layer wraps this in
    Textual's suspend() context."""
    return subprocess.call(argv)
