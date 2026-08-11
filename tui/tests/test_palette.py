import pytest

from dvw_tui.palette import PALETTES, ROLES, TOKYO, palette_for


def test_every_role_is_present():
    assert set(TOKYO) == set(ROLES)


def test_every_value_is_a_six_digit_hex():
    for role, value in TOKYO.items():
        assert value.startswith("#"), role
        assert len(value) == 7, role
        int(value[1:], 16)  # raises if not hex


def test_roles_match_the_css_variable_names():
    # theme.tcss already uses these names; a rename here silently breaks CSS.
    assert ROLES == (
        "accent", "subtle", "green", "red", "grey", "bg",
        "bg-panel", "fg", "teal", "yellow", "blue", "peach",
    )


def test_palette_for_known_name_returns_the_right_dict():
    assert palette_for("tokyo") is TOKYO


def test_palette_for_unknown_name_falls_back_to_tokyo():
    assert palette_for("nonexistent") is TOKYO


def test_palette_for_non_string_falls_back_rather_than_raising():
    assert palette_for(5) is TOKYO
    assert palette_for(None) is TOKYO
    assert palette_for(["tokyo"]) is TOKYO


def test_every_registered_palette_has_exactly_the_roles():
    for name, palette in PALETTES.items():
        assert set(palette) == set(ROLES), name


# ---------------------------------------------------------------------------
# import-time validation: PALETTES must have exactly ROLES keys and every
# value must be a well-formed #RRGGBB colour. `_validate_palettes()` runs
# once at import (this is our own data — a bad entry is a developer error,
# so raising is correct), but it's re-run directly here against a bad dict
# so the two failure shapes get their own coverage without having to
# reimport the module for each case.
# ---------------------------------------------------------------------------

def test_validate_palettes_raises_on_missing_role(monkeypatch):
    import dvw_tui.palette as P

    bad = {k: v for k, v in TOKYO.items() if k != "accent"}  # missing "accent"
    monkeypatch.setitem(P.PALETTES, "broken", bad)
    with pytest.raises(ValueError, match="broken"):
        P._validate_palettes()


def test_validate_palettes_raises_on_extra_role(monkeypatch):
    import dvw_tui.palette as P

    bad = dict(TOKYO)
    bad["nonsense"] = "#000000"
    monkeypatch.setitem(P.PALETTES, "broken", bad)
    with pytest.raises(ValueError, match="broken"):
        P._validate_palettes()


def test_validate_palettes_raises_on_malformed_hex(monkeypatch):
    import dvw_tui.palette as P

    bad = dict(TOKYO)
    bad["accent"] = "#abcdef00"  # the exact shape _lerp used to accept silently
    monkeypatch.setitem(P.PALETTES, "broken", bad)
    with pytest.raises(ValueError, match="broken"):
        P._validate_palettes()
