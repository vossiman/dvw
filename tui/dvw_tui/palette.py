"""The TUI palette — single source for render.py constants and CSS variables.

Role names match the variables theme.tcss already uses, so the same dict can
be handed to build_theme() (registered as a Textual Theme) and imported by
render.py. Two copies of the same hexes is how they drift.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from textual.theme import Theme

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


def build_theme(name: str = "dvw-tokyo", palette: dict[str, str] | None = None) -> "Theme":
    """Build a Textual `Theme` from a palette dict.

    Registering a `Theme` (rather than overriding `App.get_css_variables()`)
    is the supported route: Textual regenerates the derived variables
    (`$accent-muted`, `$text-accent`, ...) from the semantic roles below, and
    `variables` is merged over that generated set — so both Textual's
    built-ins and our own role names (`$subtle`, `$grey`, `$teal`, `$peach`,
    ...) are available to theme.tcss.

    `textual.theme` is imported locally so importing this module does not
    pull in Textual for consumers (e.g. render.py) that only need the plain
    dicts.
    """
    from textual.theme import Theme

    p = palette if palette is not None else TOKYO
    return Theme(
        name=name,
        primary=p["accent"],
        secondary=p["teal"],
        accent=p["accent"],
        warning=p["yellow"],
        error=p["red"],
        success=p["green"],
        foreground=p["fg"],
        background=p["bg"],
        surface=p["bg-panel"],
        panel=p["bg-panel"],
        dark=True,
        variables=dict(p),
    )


def palette_for(name: str) -> dict[str, str]:
    """Resolve a palette name to its dict, falling back to TOKYO.

    An unknown or non-string name falls back rather than raising — settings
    are best-effort, and a hand-edited or stale `palette` value must not
    break the TUI.
    """
    if not isinstance(name, str):
        return TOKYO
    return PALETTES.get(name, TOKYO)
