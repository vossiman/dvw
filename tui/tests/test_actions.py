from dvw_tui import actions


def test_dvw_bin_from_env(monkeypatch):
    monkeypatch.setenv("DVW_BIN", "/opt/dvw/dvw")
    assert actions.dvw_bin() == "/opt/dvw/dvw"


def test_dvw_bin_default(monkeypatch):
    monkeypatch.delenv("DVW_BIN", raising=False)
    assert actions.dvw_bin() == "dvw"


def test_argv_builders(monkeypatch):
    monkeypatch.setenv("DVW_BIN", "dvw")
    assert actions.stop("alpha") == ["dvw", "stop", "alpha"]
    assert actions.start("alpha") == ["dvw", "start", "alpha"]
    assert actions.rebuild("alpha") == ["dvw", "rebuild", "alpha"]
    assert actions.remove("alpha") == ["dvw", "rm", "alpha"]
    assert actions.connect("alpha") == ["dvw", "alpha"]
    assert actions.new() == ["dvw", "new"]
    assert actions.doctor() == ["dvw", "doctor"]


def test_connect_mode_gui_vs_terminal():
    assert actions.connect_mode("cursor") == "background"
    assert actions.connect_mode("vscode") == "background"
    assert actions.connect_mode("jetbrains") == "background"
    assert actions.connect_mode("ssh") == "suspend"
    assert actions.connect_mode("none") == "suspend"
    assert actions.connect_mode("anything-else") == "suspend"


def test_run_captured_success():
    res = actions.run_captured(["sh", "-c", "echo hi; exit 0"])
    assert res.ok and res.returncode == 0 and "hi" in res.output


def test_run_captured_failure_merges_stderr():
    res = actions.run_captured(["sh", "-c", "echo oops >&2; exit 3"])
    assert not res.ok and res.returncode == 3 and "oops" in res.output


def test_run_captured_missing_binary():
    res = actions.run_captured(["/nonexistent/definitely-not-here"])
    assert not res.ok and res.returncode == 127
