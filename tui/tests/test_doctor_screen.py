from dvw_tui import actions
from dvw_tui.actions import ActionResult
from dvw_tui.app import DvwApp
from dvw_tui.screens.doctor import DoctorScreen

FAKE_REPORT = "\x1b[1;38;2;163;190;140m[OK]\x1b[0m    catalog: readable\n"


async def test_doctor_screen_renders_report(fake_client, monkeypatch):
    monkeypatch.setattr(
        actions, "run_captured",
        lambda argv: ActionResult(ok=True, returncode=0, output=FAKE_REPORT))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(app.screen, DoctorScreen)
        log = app.screen.query_one("#doctor-log")
        # ANSI is parsed, not shown raw
        assert "[OK]" in app.screen._last_output
        # Verify no raw ESC bytes in rendered lines
        if log.lines:
            for strip in log.lines:
                for segment in strip:
                    assert "\x1b" not in segment.text


async def test_doctor_escape_returns_to_main(fake_client, monkeypatch):
    monkeypatch.setattr(
        actions, "run_captured",
        lambda argv: ActionResult(ok=True, returncode=0, output=FAKE_REPORT))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, DoctorScreen)
