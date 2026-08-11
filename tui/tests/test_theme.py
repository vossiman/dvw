"""Theme wiring: build_theme() produces a real Textual Theme, and the app
actually applies it — not merely registers it and leaves Textual's default
active."""

from dvw_tui.app import DvwApp
from dvw_tui.palette import TOKYO, build_theme


def test_build_theme_maps_semantic_roles_to_palette_roles():
    theme = build_theme(palette=TOKYO)
    assert theme.primary == TOKYO["accent"]
    assert theme.secondary == TOKYO["teal"]
    assert theme.accent == TOKYO["accent"]
    assert theme.warning == TOKYO["yellow"]
    assert theme.error == TOKYO["red"]
    assert theme.success == TOKYO["green"]
    assert theme.foreground == TOKYO["fg"]
    assert theme.background == TOKYO["bg"]
    assert theme.surface == TOKYO["bg-panel"]
    assert theme.panel == TOKYO["bg-panel"]
    assert theme.dark is True


def test_build_theme_carries_every_role_as_a_variable():
    theme = build_theme(palette=TOKYO)
    for role, value in TOKYO.items():
        assert theme.variables[role] == value


def test_theme_variables_merge_generated_and_custom():
    # The generated variable set must contain BOTH a Textual-derived
    # variable (accent-muted / text-accent, produced from `accent`) AND a
    # custom role (subtle, grey) that only our palette defines. This is the
    # test that would have caught the rejected get_css_variables() approach:
    # that approach either drops one side of this merge or leaves the
    # derived variables on Textual's default hue instead of ours.
    theme = build_theme(palette=TOKYO)
    variables = theme.to_color_system().generate()
    variables.update(theme.variables)

    assert variables["accent-muted"] != ""
    assert variables["text-accent"] != ""
    # Derived from our accent (#7dcfff), not Textual's default blue.
    assert variables["accent-muted"].lower() == "#375167"
    assert variables["text-accent"].lower() == "#a9dfff"

    assert variables["subtle"] == TOKYO["subtle"]
    assert variables["grey"] == TOKYO["grey"]


async def test_app_registers_and_selects_the_dvw_theme(fake_client):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.theme == "dvw-tokyo"
        active = app.get_theme(app.theme)
        assert active is not None
        assert active.background == TOKYO["bg"]


async def test_modal_screens_keep_a_translucent_background(fake_client):
    """Modal screens must float over the still-visible main screen.

    Regression: a bare `Screen { background: $bg }` rule in theme.tcss also
    matched every ModalScreen subclass (type selectors match subclasses, and
    the user stylesheet beats ModalScreen's DEFAULT_CSS), painting the modal
    fully opaque — opening the menu blacked out the whole tree + inspect
    pane instead of dimming them behind the box."""
    from dvw_tui.screens.confirm import ConfirmScreen
    from dvw_tui.screens.menu import MenuScreen

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        assert isinstance(app.screen, MenuScreen)
        assert app.screen.styles.background.a < 1

        await pilot.press("escape")
        await pilot.pause()
        await pilot.press("X")  # remove → ConfirmScreen
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        assert app.screen.styles.background.a < 1


async def test_pilot_renders_tokyo_colours_not_nord(fake_client):
    """Prove the theme was actually applied to a live, mounted widget — not
    merely that build_theme() holds the right string. A registered-but-never
    -selected theme, or a CSS file still hardcoding Nord hexes, would make
    this fail while the unit tests above still pass."""
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()

        screen = app.screen
        bg = screen.styles.background
        assert (bg.r, bg.g, bg.b) == (0x1A, 0x1B, 0x26)  # TOKYO["bg"]
        # Not Nord's polar-night background.
        assert (bg.r, bg.g, bg.b) != (0x2E, 0x34, 0x40)

        left = app.query_one("#left")
        _style, border_color = left.styles.border_top
        assert (border_color.r, border_color.g, border_color.b) == (
            0x7D, 0xCF, 0xFF,
        )  # TOKYO["accent"]
        # Not Nord's frost accent.
        assert (border_color.r, border_color.g, border_color.b) != (
            0x88, 0xC0, 0xD0,
        )
