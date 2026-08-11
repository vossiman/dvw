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
#
# Known limitation: only the registered Textual theme (this module) and the
# boot splash (screens/splash.py) actually follow the configured palette
# today. render.py's ACCENT/SUBTLE/GREEN/RED/GREY/BLUE/TEAL/YELLOW/PEACH
# constants are bound to TOKYO at import time, so registering a second
# palette here and pointing `palette` at it will recolour the CSS and splash
# but leave the tree/inspect pane's text still drawn in tokyo colours — a
# half-recoloured UI — until those constants are de-globalised to read from
# the resolved palette at render time instead of at import time.
PALETTES: dict[str, dict[str, str]] = {
    "tokyo": TOKYO,
}


def _validate_palettes() -> None:
    """Fail loudly at import time on our own malformed data.

    Every registered palette must have exactly the `ROLES` keys, and every
    value must be a well-formed `#RRGGBB` string — this is a developer
    error (a bad entry added to PALETTES), not a runtime condition, so
    raising here is correct: better to crash on import than to have
    `scanner._lerp` silently render a wrong colour from something like
    `"#abcdef00"`.
    """
    roles = set(ROLES)
    for name, p in PALETTES.items():
        keys = set(p)
        if keys != roles:
            missing = roles - keys
            extra = keys - roles
            detail = []
            if missing:
                detail.append(f"missing {sorted(missing)}")
            if extra:
                detail.append(f"unexpected {sorted(extra)}")
            raise ValueError(
                f"palette {name!r} has the wrong role keys: {'; '.join(detail)}")
        for key, value in p.items():
            ok = (isinstance(value, str) and len(value) == 7
                  and value.startswith("#"))
            if ok:
                try:
                    int(value[1:], 16)
                except ValueError:
                    ok = False
            if not ok:
                raise ValueError(
                    f"palette {name!r} role {key!r} is not a well-formed "
                    f"#RRGGBB colour: {value!r}")


_validate_palettes()


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
