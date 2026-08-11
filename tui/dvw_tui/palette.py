"""The TUI palette — single source for render.py constants and CSS variables.

Role names match the variables theme.tcss already uses, so the same dict can
be handed to App.get_css_variables() and imported by render.py. Two copies of
the same hexes is how they drift.
"""

from __future__ import annotations

ROLES: tuple[str, ...] = (
    "accent", "subtle", "green", "red", "grey", "bg",
    "bg-panel", "fg", "teal", "yellow", "blue", "peach",
)

TOKYO: dict[str, str] = {
    "accent": "#7dcfff",
    "subtle": "#565f89",
    "green": "#9ece6a",
    "red": "#f7768e",
    "grey": "#414868",
    "bg": "#1a1b26",
    "bg-panel": "#24283b",
    "fg": "#c0caf5",
    "teal": "#73daca",
    "yellow": "#e0af68",
    "blue": "#7aa2f7",
    "peach": "#ff9e64",
}

# Registry so the `palette` setting (stored as a name, e.g. "tokyo") can be
# resolved to a dict. Add new palettes here.
PALETTES: dict[str, dict[str, str]] = {
    "tokyo": TOKYO,
}


def palette_for(name: str) -> dict[str, str]:
    """Resolve a palette name to its dict, falling back to TOKYO.

    An unknown or non-string name falls back rather than raising — settings
    are best-effort, and a hand-edited or stale `palette` value must not
    break the TUI.
    """
    if not isinstance(name, str):
        return TOKYO
    return PALETTES.get(name, TOKYO)
