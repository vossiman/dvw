"""User settings for the TUI. Best-effort by design.

Every read and write is wrapped: a corrupt, partial or unwritable settings
file must degrade to defaults, never stop the TUI from starting.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULTS: dict[str, object] = {
    "palette": "tokyo",
    "motion": True,
}


def settings_path() -> Path:
    return Path.home() / ".config" / "dvw" / "tui.json"


def _same_type(value: object, default: object) -> bool:
    """True if `value` is a genuine match for `default`'s type.

    `bool` is a subclass of `int` in Python, so a naive `isinstance` check
    would let `motion: 5` (an int) through as if it were a bool, or a bare
    `isinstance(value, type(default))` would accept `palette: True` as a
    string. Compare exact types instead.
    """
    return type(value) is type(default)


def load_settings() -> dict:
    data = dict(DEFAULTS)
    try:
        stored = json.loads(settings_path().read_text())
        if isinstance(stored, dict):
            data.update({
                k: v for k, v in stored.items()
                if k in DEFAULTS and _same_type(v, DEFAULTS[k])
            })
    except Exception:
        pass
    return data


def save_settings(data: dict) -> None:
    try:
        path = settings_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(
            {k: v for k, v in data.items() if k in DEFAULTS}, indent=2) + "\n")
    except Exception:
        pass


def motion_enabled(data: dict) -> bool:
    """Env var wins — it is the escape hatch for CI and slow ssh links.

    The spec only names `DVW_TUI_MOTION=0`, but after stripping whitespace
    and lower-casing, `"false"`, `"no"`, `"off"` and the empty string are
    also treated as falsy — a deliberate, documented tolerance rather than
    an accident of string comparison.
    """
    env = os.environ.get("DVW_TUI_MOTION")
    if env is not None:
        return env.strip().lower() not in ("0", "false", "no", "off", "")
    return bool(data.get("motion", True))
