"""Correct spacing between a status glyph and its label.

Some marks render two cells wide in common terminal fonts (emoji
presentation) while Rich and Textual lay them out as one. The glyph then
overdraws the space after it, and `⚠ stale` reads as cramped where
`● running` reads correctly. The compensation is a second space.

This CANNOT be derived. `unicodedata.east_asian_width` calls both ⚠ and ⏸
"N" (Neutral), and `rich.cells.get_character_cell_size` reports 1 for both —
because the double-width rendering comes from the font, not the codepoint.
Hence an explicit set, extended when a mark is observed to over-render.
"""

from __future__ import annotations

WIDE_MARKS = frozenset({
    "⚠",   # U+26A0 warning  — liveness "stale"
    "⏸",   # U+23F8 pause    — tree-view "waiting" badge
})


def glyph(mark: str, label: str) -> str:
    if not mark:
        return label
    if not label:
        return mark
    gap = "  " if mark[0] in WIDE_MARKS else " "
    return f"{mark}{gap}{label}"
