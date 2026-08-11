import unicodedata

import pytest

from dvw_tui.glyphs import WIDE_MARKS, glyph


@pytest.mark.parametrize("mark", ["●", "○", "✗", "↑", "⇄", "⚑", "▸"])
def test_narrow_marks_get_one_space(mark):
    assert glyph(mark, "running") == f"{mark} running"


@pytest.mark.parametrize("mark", ["⚠", "⏸"])
def test_emoji_presentation_marks_get_two_spaces(mark):
    # These render two cells wide in the terminal font while Rich lays them
    # out as one, so the glyph overdraws the following space.
    assert glyph(mark, "stale") == f"{mark}  stale"


def test_the_wide_set_is_curated_not_derived():
    # Guards the reasoning: if someone "simplifies" this to east_asian_width,
    # this test fails, because Unicode calls both of these Neutral.
    for mark in WIDE_MARKS:
        assert unicodedata.east_asian_width(mark) not in ("W", "F")


def test_numeric_labels_are_spaced_too():
    assert glyph("↑", "2") == "↑ 2"


def test_empty_label_yields_just_the_mark():
    assert glyph("●", "") == "●"


def test_empty_mark_yields_just_the_label():
    assert glyph("", "running") == "running"
