"""KITT scanner: a bright band sweeping the wordmark and back.

Pure — text and a palette in, Rich Text frames out. No terminal, no clock, no
third-party effects library. Each frame is a direct function of the sweep
position, which is why generating a full-screen animation costs ~20ms rather
than the 70-1700ms the terminaltexteffects equivalents measured at.
"""

from __future__ import annotations

from rich.text import Text

# Falloff bands, in cells from the sweep centre.
_CORE = 1.5     # inside this, the hot colour
_GLOW = 6.0     # accent -> hot
_TAIL = 16.0    # base -> accent


def _lerp(a: str, b: str, t: float) -> str:
    t = max(0.0, min(1.0, t))
    ar, ag, ab = (int(a[i:i + 2], 16) for i in (1, 3, 5))
    br, bg, bb = (int(b[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % (
        round(ar + (br - ar) * t),
        round(ag + (bg - ag) * t),
        round(ab + (bb - ab) * t),
    )


def _block(art: str) -> tuple[list[str], int]:
    lines = art.split("\n")
    width = max((len(line) for line in lines), default=1)
    return [line.ljust(width) for line in lines], width


def _frame(lines: list[str], centre: float | None,
           base: str, band: str, core: str) -> Text:
    out = Text()
    for row, line in enumerate(lines):
        if row:
            out.append("\n")
        for i, ch in enumerate(line):
            if ch == " ":
                out.append(" ")
            elif centre is None:
                out.append(ch, style=f"bold {band}")
            else:
                d = abs(i - centre)
                if d < _CORE:
                    out.append(ch, style=f"bold {core}")
                elif d < _GLOW:
                    out.append(ch, style=_lerp(band, core, 1 - (d - _CORE) / (_GLOW - _CORE)))
                elif d < _TAIL:
                    out.append(ch, style=_lerp(base, band, 1 - (d - _GLOW) / (_TAIL - _GLOW)))
                else:
                    out.append(ch, style=base)
    return out


def _colours(palette: dict[str, str]) -> tuple[str, str, str]:
    return palette["grey"], palette["accent"], palette["fg"]


def scanner_settled(art: str, palette: dict[str, str]) -> Text:
    """The flat wordmark. Only for the motion-disabled path.

    The animation never ends on this: snapping to a flat repaint reads as the
    logo being redrawn rather than the scanner coming to rest.
    """
    lines, _ = _block(art)
    base, band, core = _colours(palette)
    return _frame(lines, None, base, band, core)


def scanner_frames(art: str, palette: dict[str, str], period_ms: int,
                   fps: int = 30, loop: bool = False) -> list[Text]:
    """One sweep across and back, as `period_ms` worth of frames at `fps`.

    Decoration must never break the tool, so every failure — a period of zero,
    a palette missing roles, malformed art — returns the single settled frame.
    That makes the kill switch and the error path the same code path, so the
    degraded mode is exercised whenever someone disables motion.
    """
    try:
        base, band, core = _colours(palette)
        lines, width = _block(art)
        if period_ms <= 0:
            return [_frame(lines, None, base, band, core)]
        n = max(2, round(period_ms / 1000 * fps))
        frames = []
        for f in range(n):
            # Half-open for a loop so the strip is a true cycle; inclusive for
            # a one-shot so it ends where it started.
            p = f / n if loop else (f / (n - 1))
            centre = (1 - abs(2 * p - 1)) * (width - 1)
            frames.append(_frame(lines, centre, base, band, core))
        return frames
    except Exception:
        try:
            return [scanner_settled(art, palette)]
        except Exception:
            return [Text(art)]
