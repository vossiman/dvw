"""Pure rendering helpers — everything here is testable without a terminal."""

from __future__ import annotations

from rich.text import Text

# Nord palette — mirrors lib/ui.sh. theme.tcss carries the same values for CSS.
ACCENT = "#88c0d0"
SUBTLE = "#616e88"
GREEN = "#a3be8c"
RED = "#bf616a"
GREY = "#4c566a"
BLUE = "#81a1c1"
TEAL = "#8fbcbb"
YELLOW = "#ebcb8b"
PEACH = "#d08770"

_LIVENESS = {
    "alive":   ("● running", GREEN, False),
    "stale":   ("⚠ stale",   RED,   True),
    "stopped": ("○ stopped", GREY,  False),
    "absent":  ("✗ absent",  RED,   True),
}

_IDE_COLORS = {"cursor": TEAL, "ssh": YELLOW, "vscode": BLUE, "jetbrains": PEACH}


def liveness_cell(liveness: str) -> Text:
    label, color, bold = _LIVENESS.get(liveness, ("? unknown", GREY, False))
    return Text(label, style=f"bold {color}" if bold else color)


def ide_color(ide: str) -> str:
    return _IDE_COLORS.get(ide, GREY)


def ide_cell(ide: str) -> Text:
    return Text(ide, style=ide_color(ide))


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
