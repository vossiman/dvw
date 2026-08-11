from dvw_tui.client import WindowInfo
from dvw_tui.glyphs import glyph
from dvw_tui.palette import TOKYO
from dvw_tui.render import (
    ACCENT,
    BLUE,
    GREEN,
    GREY,
    PEACH,
    RED,
    SUBTLE,
    TEAL,
    YELLOW,
    age,
    human_bytes,
    liveness_cell,
    ide_color,
    meter,
    state_cell,
    window_label,
)


def test_color_constants_come_from_the_palette():
    # render.py's nine colour constants must be lookups into TOKYO, not
    # literals that can drift from theme.tcss's copy. bg/bg-panel/fg are
    # CSS-only and have no render.py counterpart, so this checks nine, not
    # all twelve ROLES.
    assert ACCENT == TOKYO["accent"]
    assert SUBTLE == TOKYO["subtle"]
    assert GREEN == TOKYO["green"]
    assert RED == TOKYO["red"]
    assert GREY == TOKYO["grey"]
    assert BLUE == TOKYO["blue"]
    assert TEAL == TOKYO["teal"]
    assert YELLOW == TOKYO["yellow"]
    assert PEACH == TOKYO["peach"]


def test_human_bytes():
    assert human_bytes(None) == "—"
    assert human_bytes(512) == "512 B"
    assert human_bytes(2048) == "2.0 KiB"
    assert human_bytes(3 * 1024**3) == "3.0 GiB"

def test_liveness_cell_glyphs_and_styles():
    assert liveness_cell("alive").plain == glyph("●", "running")
    assert liveness_cell("stale").plain == glyph("⚠", "stale")
    assert liveness_cell("stopped").plain == glyph("○", "stopped")
    assert liveness_cell("absent").plain == glyph("✗", "absent")
    assert liveness_cell("whatever").plain == glyph("?", "unknown")
    assert "#9ece6a" in str(liveness_cell("alive").style)


def test_liveness_cell_wide_marks_get_two_spaces():
    # The user-visible bug this task fixes: ⚠ and ⏸ render two cells wide in
    # common terminal fonts, so they need a second space to avoid overdrawing
    # the label. Narrow marks like ● keep a single space.
    assert liveness_cell("stale").plain == "⚠  stale"
    assert liveness_cell("alive").plain == "● running"

def test_ide_color():
    assert ide_color("cursor") == "#73daca"
    assert ide_color("ssh") == "#e0af68"
    assert ide_color("vscode") == "#7aa2f7"
    assert ide_color("jetbrains") == "#ff9e64"
    assert ide_color("none") == "#414868"

def test_meter():
    assert meter(None) == "—"
    bar = meter(50.0)
    assert "50%" in bar and "▰" in bar and "▱" in bar
    assert meter(0.0).count("▰") == 0
    assert meter(100.0).count("▱") == 0

def test_state_cell_shows_attached_suffix():
    text = state_cell("alive", 2)
    assert "⇄ 2" in text.plain
    assert "running" in text.plain


def test_state_cell_no_suffix_when_zero_or_not_running():
    assert "⇄" not in state_cell("alive", 0).plain
    assert "⇄" not in state_cell("stopped", 2).plain
    assert "⇄" not in state_cell("absent", 1).plain


def test_state_cell_stale_shows_suffix():
    assert "⇄ 1" in state_cell("stale", 1).plain


def test_age_formats_minutes_and_hours():
    now = 10_000
    assert age(now - 90, now) == "1m"
    assert age(now - 3600, now) == "1h"
    assert age(now, now) == "0m"


def test_age_clamps_negative_delta():
    assert age(100, 50) == "0m"


def test_window_label_full():
    now = 10_000
    w = WindowInfo(
        window_id="1",
        name="build",
        active=True,
        activity=now - 120,
        waiting_since=now - 60,
        command="make test",
    )
    label = window_label(w, now)
    plain = label.plain
    assert "❘ build" in plain
    assert "▸ make test" in plain
    assert " *" in plain
    assert "2m" in plain
    assert glyph("⏸", "waiting 1m") in plain


def test_window_label_minimal():
    w = WindowInfo(window_id="2", name="idle", active=False, activity=-1,
                    waiting_since=None, command="")
    label = window_label(w, 10_000)
    plain = label.plain
    assert plain == "❘ idle"
    assert "▸" not in plain
    assert "*" not in plain
    assert "⏸" not in plain


def test_window_label_waiting_glyph_is_spaced():
    now = 10_000
    w = WindowInfo(window_id="3", name="w", active=False, activity=-1,
                    waiting_since=now - 30, command="")
    label = window_label(w, now)
    assert glyph("⏸", "waiting") in label.plain
    assert "⏸waiting" not in label.plain


def test_window_label_waiting_style_is_accent_bold():
    now = 10_000
    w = WindowInfo(window_id="4", name="w", active=False, activity=-1,
                    waiting_since=now - 30, command="")
    label = window_label(w, now)
    # find the span covering the waiting badge and check its style
    idx = label.plain.index("⏸")
    styles = [s.style for s in label.spans if s.start <= idx < s.end]
    assert any("bold" in str(s) and "#7dcfff" in str(s) for s in styles)
