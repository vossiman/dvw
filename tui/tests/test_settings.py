import json

import pytest

from dvw_tui import settings as S


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("DVW_TUI_MOTION", raising=False)
    return tmp_path


def test_defaults_when_no_file_exists():
    assert S.load_settings() == S.DEFAULTS


def test_round_trip():
    S.save_settings({"palette": "tokyo", "motion": False})
    assert S.load_settings()["motion"] is False


def test_partial_file_merges_over_defaults():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"motion": False}))
    loaded = S.load_settings()
    assert loaded["motion"] is False
    assert loaded["palette"] == S.DEFAULTS["palette"]


def test_corrupt_file_falls_back_to_defaults():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text("{not json")
    assert S.load_settings() == S.DEFAULTS


def test_unknown_keys_are_ignored():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"nonsense": 1, "motion": False}))
    loaded = S.load_settings()
    assert "nonsense" not in loaded
    assert loaded["motion"] is False


def test_unwritable_location_does_not_raise(monkeypatch):
    monkeypatch.setattr(S, "settings_path", lambda: __import__("pathlib").Path("/proc/x/y.json"))
    S.save_settings({"motion": True})  # must not raise


def test_env_var_overrides_the_file(monkeypatch):
    # File says motion is off; env says on. Env must win — this is the
    # enable direction, which had no coverage before this fix.
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"motion": False}))
    monkeypatch.setenv("DVW_TUI_MOTION", "1")
    assert S.motion_enabled(S.load_settings()) is True


def test_env_var_zero_disables_motion(monkeypatch):
    monkeypatch.setenv("DVW_TUI_MOTION", "0")
    S.save_settings({"motion": True})
    assert S.motion_enabled(S.load_settings()) is False


@pytest.mark.parametrize("value", ["0", "false", "no", "off", "",
                                    "FALSE", "Off", "  no  "])
def test_env_var_falsy_values_disable_motion(monkeypatch, value):
    monkeypatch.setenv("DVW_TUI_MOTION", value)
    S.save_settings({"motion": True})
    assert S.motion_enabled(S.load_settings()) is False


def test_wrong_typed_motion_falls_back_to_default():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"motion": "false"}))
    loaded = S.load_settings()
    assert loaded["motion"] is S.DEFAULTS["motion"]


def test_wrong_typed_palette_falls_back_to_default():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"palette": 5}))
    loaded = S.load_settings()
    assert loaded["palette"] == S.DEFAULTS["palette"]


def test_mixed_file_keeps_the_valid_key_and_drops_the_invalid_one():
    S.settings_path().parent.mkdir(parents=True, exist_ok=True)
    S.settings_path().write_text(json.dumps({"motion": False, "palette": 5}))
    loaded = S.load_settings()
    assert loaded["motion"] is False
    assert loaded["palette"] == S.DEFAULTS["palette"]


def test_bool_is_not_accepted_for_an_int_like_setting():
    # Guard against `isinstance(value, type(default))` false positives: bool
    # is a subclass of int, so a naive isinstance check on an int-typed
    # default would accept a bool. There's no int-typed setting today, so
    # this exercises `_same_type` directly.
    assert S._same_type(True, 1) is False
    assert S._same_type(5, True) is False
