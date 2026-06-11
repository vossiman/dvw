"""App-level action plumbing. Subprocess layers are monkeypatched —
we assert the right argv/mode is chosen, not that devpod runs."""

import contextlib

from textual.widgets import OptionList

from dvw_tui import actions
from dvw_tui.app import DvwApp
from dvw_tui.screens.confirm import ConfirmScreen
from dvw_tui.screens.connect import ConnectScreen


async def test_connect_gui_runs_background(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(actions, "run_background", lambda argv: calls.setdefault("bg", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")          # alpha -> ConnectScreen
        await pilot.pause()
        assert isinstance(app.screen, ConnectScreen)
        option_list = app.screen.query_one("#connect-list", OptionList)
        # alpha's catalog ide is cursor -> cursor preselected
        assert option_list.get_option_at_index(option_list.highlighted).id == "cursor"
        await pilot.press("enter")          # cursor -> background
        await pilot.pause()
        assert calls["bg"] == ["dvw", "alpha", "--cursor"]


async def test_connect_terminal_suspends(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("down")           # focus beta, ide=ssh
        await pilot.pause()
        await pilot.press("enter")          # -> ConnectScreen
        await pilot.pause()
        assert isinstance(app.screen, ConnectScreen)
        option_list = app.screen.query_one("#connect-list", OptionList)
        assert option_list.get_option_at_index(option_list.highlighted).id == "ssh"
        await pilot.press("enter")          # ssh -> suspend
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "beta", "--ssh"]


async def test_stop_runs_suspended(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "stop", "alpha"]


async def test_rebuild_asks_confirmation_then_runs(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    monkeypatch.setenv("DVW_BIN", "dvw")
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("r")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("y")
        await pilot.pause()
        assert calls["suspended"] == ["dvw", "rebuild", "alpha"]


async def test_confirm_dismissed_with_n_does_nothing(fake_client, monkeypatch):
    calls = {}
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True:
            calls.setdefault("suspended", argv))
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("X")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("n")
        await pilot.pause()
        assert "suspended" not in calls


# ---------------------------------------------------------------------------
# _run_suspended: rc passthrough and Ctrl-C safety
# ---------------------------------------------------------------------------

def _make_app_with_noop_suspend(fake_client, monkeypatch):
    """Return a DvwApp with suspend() patched to a no-op and _refresh_main
    patched to a no-op so _run_suspended can be called directly (outside a
    Textual pilot context where self.suspend() raises SuspendNotSupported)."""
    monkeypatch.setattr(DvwApp, "suspend", lambda self: contextlib.nullcontext())
    monkeypatch.setattr(DvwApp, "_refresh_main", lambda self: None)
    return DvwApp(client=fake_client)


def test_run_suspended_returns_rc(fake_client, monkeypatch):
    """_run_suspended must propagate the subprocess exit code to the caller."""
    monkeypatch.setattr(actions, "run_interactive", lambda argv: 3)
    monkeypatch.setattr("builtins.input", lambda prompt="": "")
    app = _make_app_with_noop_suspend(fake_client, monkeypatch)
    rc = app._run_suspended(["dvw", "stop", "alpha"])
    assert rc == 3


def test_run_suspended_keyboard_interrupt_returns_130(fake_client, monkeypatch):
    """KeyboardInterrupt during the subprocess must be caught and returned as
    rc=130 — no exception must escape _run_suspended."""
    def raise_sigint(argv):
        raise KeyboardInterrupt

    monkeypatch.setattr(actions, "run_interactive", raise_sigint)
    monkeypatch.setattr("builtins.input", lambda prompt="": "")
    app = _make_app_with_noop_suspend(fake_client, monkeypatch)
    rc = app._run_suspended(["dvw", "stop", "alpha"])
    assert rc == 130


# ---------------------------------------------------------------------------
# do_simple_action: rc-aware toast
# ---------------------------------------------------------------------------

async def test_simple_action_success_toast(fake_client, monkeypatch):
    """On rc=0 do_simple_action sends a plain (non-error) notify."""
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True: 0)
    monkeypatch.setenv("DVW_BIN", "dvw")

    notify_calls = []
    monkeypatch.setattr(
        DvwApp, "notify",
        lambda self, message, title="", severity="information", **kw:
            notify_calls.append({"message": message, "severity": severity}))

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")   # stop on alpha (first row focused by default)
        await pilot.pause()

    success = [c for c in notify_calls if "failed" not in c["message"]]
    assert success, "expected a success notify"
    assert success[-1]["severity"] == "information"
    assert "alpha" in success[-1]["message"]


async def test_simple_action_failure_toast(fake_client, monkeypatch):
    """On non-zero rc do_simple_action sends an error-severity notify."""
    monkeypatch.setattr(
        DvwApp, "_run_suspended", lambda self, argv, pause_on_fail=True: 5)
    monkeypatch.setenv("DVW_BIN", "dvw")

    notify_calls = []
    monkeypatch.setattr(
        DvwApp, "notify",
        lambda self, message, title="", severity="information", **kw:
            notify_calls.append({"message": message, "severity": severity}))

    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause()

    error = [c for c in notify_calls if c["severity"] == "error"]
    assert error, "expected an error-severity notify"
    assert "failed" in error[-1]["message"]
    assert "rc=5" in error[-1]["message"]
