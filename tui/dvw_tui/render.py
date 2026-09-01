"""Pure rendering helpers — everything here is testable without a terminal."""

from __future__ import annotations

from rich.text import Text

from .client import WindowInfo
from .glyphs import glyph
from .palette import TOKYO

# Colours come from the palette — the single source shared with theme.tcss.
ACCENT = TOKYO["accent"]
SUBTLE = TOKYO["subtle"]
GREEN = TOKYO["green"]
RED = TOKYO["red"]
GREY = TOKYO["grey"]
YELLOW = TOKYO["yellow"]

_LIVENESS = {
    "alive":   ("●", "running", GREEN, False),
    "stale":   ("⚠", "stale",   RED,   True),
    "stopped": ("○", "stopped", GREY,  False),
    "absent":  ("✗", "absent",  RED,   True),
}

def liveness_cell(liveness: str) -> Text:
    mark, label, color, bold = _LIVENESS.get(liveness, ("?", "unknown", GREY, False))
    return Text(glyph(mark, label), style=f"bold {color}" if bold else color)


def state_cell(liveness: str, attached: int = 0,
               image_current: bool | None = None) -> Text:
    """liveness_cell plus `⇄ N` for attached clients and `⬆` when the
    container runs an image older than the blueprint. Tri-state on purpose:
    None (unknown) renders nothing, only an actual False earns the badge."""
    text = liveness_cell(liveness)
    if attached >= 1 and liveness in ("alive", "stale"):
        text.append(f" {glyph('⇄', str(attached))}", style=f"bold {ACCENT}")
    if image_current is False:
        text.append(f" {glyph('⬆', 'outdated')}", style=f"bold {YELLOW}")
    return text


def human_bytes(n: int | None) -> str:
    if n is None:
        return "—"
    value = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TiB"


def meter(pct: float | None, width: int = 10) -> str:
    """Compact block meter: '▰▰▰▱▱▱▱▱▱▱  30%'."""
    if pct is None:
        return "—"
    filled = round(max(0.0, min(100.0, pct)) / 100 * width)
    return "▰" * filled + "▱" * (width - filled) + f"  {pct:.0f}%"


def inspect_lines(data: dict) -> list[tuple[str, str]]:
    """(label, value) pairs for the inspect pane, in display order."""
    mem = human_bytes(data.get("mem_bytes"))
    if data.get("mem_limit"):
        mem += f" / {human_bytes(data['mem_limit'])}"
    pairs = [
        ("container", data.get("container_name") or "—"),
        ("status", data.get("status") or "—"),
        ("health", data.get("health") or "—"),
        ("image", data.get("image") or "—"),
        ("started", data.get("started_at") or "—"),
        ("restarts", str(data.get("restart_count", 0))),
        ("cpu", meter(data.get("cpu_pct"))),
        ("memory", f"{meter(data.get('mem_pct'))}   {mem}"),
        ("disk", human_bytes(data.get("disk_bytes"))),
    ]
    for m in data.get("bind_mounts", []):
        rw = "rw" if m.get("rw", True) else "ro"
        pairs.append(("mount", f"{m['source']} → {m['destination']} ({rw})"))
    return pairs


def age(epoch: int, now: int) -> str:
    """Elapsed time since `epoch` as a compact '<N>m' / '<N>h' / '<N>d'
    string."""
    d = max(0, now - epoch)
    if d >= 86_400:
        return f"{d // 86_400}d"
    return f"{d // 3600}h" if d >= 3600 else f"{d // 60}m"


def window_label(w: WindowInfo, now: int) -> Text:
    """Single-line label for a tmux window row in the tree view.

    `❘ <name>  ▸ <command>` (command omitted when empty), ` *` when active,
    `  <age>` from `activity` (omitted when -1), and `  ⏸ waiting <age>`
    (bold ACCENT) from `waiting_since` when the window is waiting. The gap
    after each glyph comes from `glyph()`, not this function.
    """
    text = Text(glyph("❘", w.name))
    if w.command:
        text.append(f"  {glyph('▸', w.command)}", style=SUBTLE)
    if w.active:
        text.append(" *")
    if w.activity >= 0:
        text.append(f"  {age(w.activity, now)}", style=SUBTLE)
    if w.waiting_since is not None:
        text.append(f"  {glyph('⏸', f'waiting {age(w.waiting_since, now)}')}", style=f"bold {ACCENT}")
    return text
