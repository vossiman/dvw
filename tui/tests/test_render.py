from dvw_tui.render import human_bytes, liveness_cell, ide_color, meter

def test_human_bytes():
    assert human_bytes(None) == "—"
    assert human_bytes(512) == "512 B"
    assert human_bytes(2048) == "2.0 KiB"
    assert human_bytes(3 * 1024**3) == "3.0 GiB"

def test_liveness_cell_glyphs_and_styles():
    assert liveness_cell("alive").plain == "● running"
    assert liveness_cell("stale").plain == "⚠ stale"
    assert liveness_cell("stopped").plain == "○ stopped"
    assert liveness_cell("absent").plain == "✗ absent"
    assert liveness_cell("whatever").plain == "? unknown"
    assert "#a3be8c" in str(liveness_cell("alive").style)

def test_ide_color():
    assert ide_color("cursor") == "#8fbcbb"
    assert ide_color("ssh") == "#ebcb8b"
    assert ide_color("vscode") == "#81a1c1"
    assert ide_color("jetbrains") == "#d08770"
    assert ide_color("none") == "#4c566a"

def test_meter():
    assert meter(None) == "—"
    bar = meter(50.0)
    assert "50%" in bar and "▰" in bar and "▱" in bar
    assert meter(0.0).count("▰") == 0
    assert meter(100.0).count("▱") == 0
