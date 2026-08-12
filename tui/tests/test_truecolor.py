"""Truecolor negotiation: the TUI must not fall back to Rich's 256- or
16-colour ("DOS palette") rendering just because the launch environment
lost COLORTERM — which every ssh hop and bare tmux session does."""

import os

from dvw_tui.app import DvwApp, _ensure_truecolor


def test_sets_colorterm_when_absent(monkeypatch):
    monkeypatch.delenv("COLORTERM", raising=False)
    _ensure_truecolor()
    assert os.environ["COLORTERM"] == "truecolor"


def test_preserves_an_existing_colorterm(monkeypatch):
    monkeypatch.setenv("COLORTERM", "24bit")
    _ensure_truecolor()
    assert os.environ["COLORTERM"] == "24bit"


def test_opt_out_leaves_the_environment_alone(monkeypatch):
    monkeypatch.delenv("COLORTERM", raising=False)
    monkeypatch.setenv("DVW_TUI_NO_TRUECOLOR", "1")
    _ensure_truecolor()
    assert "COLORTERM" not in os.environ


def test_main_negotiates_truecolor_before_running_the_app(monkeypatch):
    """main() must call the helper before the app (and its Rich console,
    which reads COLORTERM at construction time) comes up."""
    from dvw_tui import app as app_mod

    monkeypatch.delenv("COLORTERM", raising=False)
    seen = {}
    monkeypatch.setattr(
        DvwApp, "run",
        lambda self: seen.setdefault("colorterm", os.environ.get("COLORTERM")))
    app_mod.main()
    assert seen["colorterm"] == "truecolor"
