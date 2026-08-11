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
