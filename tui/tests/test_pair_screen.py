from dvw_tui import actions
from dvw_tui.app import DvwApp
from dvw_tui.screens.pair import PairScreen


class FakeResult:
    def __init__(self, ok: bool, output: str, returncode: int = 0):
        self.ok = ok
        self.output = output
        self.returncode = returncode


async def test_pair_screen_shows_pair_output(fake_client, monkeypatch):
    calls = {}

    def fake_captured(argv):
        calls["argv"] = argv
        return FakeResult(True, "QR-BLOCK\nhttps://app.paseo.sh/#offer=x")

    monkeypatch.setattr(actions, "run_captured", fake_captured)
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(PairScreen(workspace_id="alpha"))
        await pilot.pause()
        # worker thread renders into the RichLog
        for _ in range(20):
            await pilot.pause(0.05)
            if calls:
                break
        assert calls["argv"] == actions.pair_paseo("alpha")
        assert isinstance(app.screen, PairScreen)


async def test_pair_screen_failure_shows_hint(fake_client, monkeypatch):
    monkeypatch.setattr(
        actions, "run_captured",
        lambda argv: FakeResult(False, "ssh: connect failed", returncode=255),
    )
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        screen = PairScreen(workspace_id="alpha")
        app.push_screen(screen)
        for _ in range(20):
            await pilot.pause(0.05)
            if screen.last_result is not None:
                break
        assert screen.last_result is not None
        assert screen.last_result.ok is False
