"""The DVW wordmark — figlet `ansi_shadow`, vendored.

We need exactly one word in exactly one font, so the six lines live here as a
constant rather than pulling in pyfiglet to regenerate them on every launch.
"""

from __future__ import annotations

DVW_ART: tuple[str, ...] = (
    "██████╗ ██╗   ██╗██╗    ██╗",
    "██╔══██╗██║   ██║██║    ██║",
    "██║  ██║██║   ██║██║ █╗ ██║",
    "██║  ██║╚██╗ ██╔╝██║███╗██║",
    "██████╔╝ ╚████╔╝ ╚███╔███╔╝",
    "╚═════╝   ╚═══╝   ╚══╝╚══╝ ",
)

SUBTITLE = "workspace orchestrator"


def wordmark(subtitle: str = SUBTITLE) -> str:
    """Art + blank row + centred subtitle, as one equal-width block.

    No margins are added around the block: the splash widget centres it via
    `content-align: center middle`, and padding here as well would centre an
    already-centred block and push it off.
    """
    width = max(max(len(line) for line in DVW_ART), len(subtitle))
    pad = (width - len(subtitle)) // 2
    rows = [*DVW_ART, "", " " * pad + subtitle]
    return "\n".join(row.ljust(width) for row in rows)
