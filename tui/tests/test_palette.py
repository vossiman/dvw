from dvw_tui.palette import ROLES, TOKYO


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
