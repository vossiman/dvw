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
    assert actions.remove("alpha") == ["dvw", "rm", "alpha", "--yes"]
    assert actions.connect("alpha") == ["dvw", "alpha"]
    assert actions.doctor() == ["dvw", "doctor"]


def test_connect_with_explicit_mode(monkeypatch):
    monkeypatch.setenv("DVW_BIN", "dvw")
    assert actions.connect("alpha", "ssh") == ["dvw", "alpha", "--ssh"]
    assert actions.connect("alpha", "cursor") == ["dvw", "alpha", "--cursor"]
    assert actions.connect("alpha", "both") == ["dvw", "alpha", "--both"]
    assert actions.connect("alpha", None) == ["dvw", "alpha"]


def test_connect_with_window_forces_ssh_and_appends_flag(monkeypatch):
    monkeypatch.setenv("DVW_BIN", "dvw")
    assert actions.connect("alpha", "ssh", window="@7") == \
        ["dvw", "alpha", "--ssh", "--window", "@7"]
    # window implies ssh even when mode is None
    assert actions.connect("alpha", window="@7") == \
        ["dvw", "alpha", "--ssh", "--window", "@7"]


def test_connect_without_window_unchanged(monkeypatch):
    monkeypatch.setenv("DVW_BIN", "dvw")
    assert actions.connect("alpha") == ["dvw", "alpha"]
    assert actions.connect("alpha", "cursor") == ["dvw", "alpha", "--cursor"]


def test_connect_mode_maps_mode_to_execution_style():
    assert actions.connect_mode("cursor") == "background"
    assert actions.connect_mode("ssh") == "suspend"
    assert actions.connect_mode("both") == "suspend"
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


def test_new_list_branches():
    assert actions.new_list_branches("R") == ["dvw", "new", "--list-branches", "R"]


def test_new_check_devcontainer():
    assert actions.new_check_devcontainer("R", "b") == [
        "dvw", "new", "--check-devcontainer", "R", "b"]


def test_new_create_full_flags():
    assert actions.new_create("R", "b", "n",
                              init_empty=True, seed_devcontainer=True) == [
        "dvw", "new", "--repo", "R", "--branch", "b", "--name", "n",
        "--init-empty", "--seed-devcontainer", "--yes"]


def test_new_create_minimal():
    assert actions.new_create("R", "b", "n") == [
        "dvw", "new", "--repo", "R", "--branch", "b", "--name", "n", "--yes"]


def test_run_captured_split_discards_stderr():
    """The plumbing probes' stdout is a contract (line 1 = resolved URL);
    stderr noise (update nudge, ui_progress markers) must not reach it."""
    res = actions.run_captured_split(
        ["sh", "-c", "echo '⬆ 3 behind main' >&2; "
                     "printf 'git@github.com:o/r.git\\nmain\\n'; exit 0"])
    assert res.ok and res.returncode == 0
    assert res.output.splitlines() == ["git@github.com:o/r.git", "main"]
    assert "behind main" not in res.output


def test_run_captured_split_passes_rc_through():
    res = actions.run_captured_split(["sh", "-c", "echo noise >&2; exit 3"])
    assert not res.ok and res.returncode == 3 and res.output == ""


def test_run_captured_split_missing_binary():
    res = actions.run_captured_split(["/nonexistent/definitely-not-here"])
    assert not res.ok and res.returncode == 127
