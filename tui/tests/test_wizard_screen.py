"""WizardScreen pilot tests. actions.run_captured_split is monkeypatched (see
the fake_new_cli fixture in conftest.py) — the wizard's subprocess calls
resolve instantly from canned results, so no `dvw` binary is ever executed.
One test deliberately opts out and drives a real `dvw` stand-in script to
pin the stdout-only contract end to end."""

from textual.widgets import Input, OptionList

from dvw_tui import actions
from dvw_tui.app import DvwApp
from dvw_tui.screens.wizard import NEW_REPO_OPTION, WizardScreen


async def test_happy_path_dismisses_with_result(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")         # past "+ enter new…"
        await pilot.press("enter")        # pick first catalog repo
        await pilot.pause(0.2)            # branch fetch worker
        await pilot.press("enter")        # pick branch "main"
        await pilot.pause(0.2)            # devcontainer check (rc 0 -> no confirm)
        await pilot.press("enter")        # accept default name
        await pilot.pause()
        await pilot.press("enter")        # IDE default (cursor)
        await pilot.pause()
        await pilot.press("y")            # summary confirm
        await pilot.pause()
    assert len(results) == 1 and results[0] is not None
    r = results[0]
    assert r.repo == "git@github.com:vossiman/alpha.git"   # resolved URL wins
    assert r.branch == "main"
    assert r.name == "alpha-main"
    assert r.ide == "cursor"
    assert not r.init_empty and not r.seed_devcontainer


async def test_repo_step_lists_new_option_first(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen())
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, WizardScreen)
        option_list = screen.query_one("#wizard-repo-list")
        labels = [str(o.prompt) for o in option_list.options]
        assert labels[0] == NEW_REPO_OPTION
        assert "https://github.com/vossiman/alpha.git" in labels


async def test_escape_dismisses_none(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert results == [None]


async def test_escape_from_name_input_dismisses_none(fake_client, fake_new_cli):
    """The escape binding is priority — an focused Input must not swallow it."""
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        assert app.screen.query("#wizard-name-input")
        await pilot.press("escape")
        await pilot.pause()
    assert results == [None]


async def test_escape_during_fetch_survives_late_worker(
    fake_client, fake_new_cli, monkeypatch
):
    """Aborting while a probe thread is still running must dismiss exactly
    once — the worker's late result may not resurrect or re-dismiss."""
    import time

    from dvw_tui.actions import ActionResult

    def slow_run_captured(argv):
        time.sleep(0.3)
        return ActionResult(ok=True, returncode=0,
                            output="git@github.com:vossiman/alpha.git\nmain\n")

    monkeypatch.setattr(actions, "run_captured_split", slow_run_captured)

    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")        # kicks the branch-fetch worker
        await pilot.press("escape")       # abort while it is still running
        await pilot.pause(0.6)            # let the worker finish and report
    assert results == [None]


async def test_empty_repo_offers_init(fake_client, fake_new_cli):
    fake_new_cli["branches"] = (3, "git@github.com:vossiman/alpha.git\n")
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")        # repo
        await pilot.pause(0.2)
        await pilot.press("y")            # confirm init-empty
        await pilot.pause()
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")            # summary
        await pilot.pause()
    r = results[0]
    assert r.init_empty and r.branch == "main"
    assert r.repo == "git@github.com:vossiman/alpha.git"
    # No devcontainer check runs for a freshly initialised repo.
    assert not any("--check-devcontainer" in argv for argv in fake_new_cli["calls"])


async def test_empty_repo_decline_aborts(fake_client, fake_new_cli):
    fake_new_cli["branches"] = (3, "git@github.com:vossiman/alpha.git\n")
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("n")            # decline init-empty
        await pilot.pause()
    assert results == [None]


async def test_missing_devcontainer_offers_seed(fake_client, fake_new_cli):
    fake_new_cli["devcontainer_rc"] = 1
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("y")            # confirm seed
        await pilot.pause()
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].seed_devcontainer


async def test_missing_devcontainer_decline_continues(fake_client, fake_new_cli):
    """Declining the seed offer is not an abort — the wizard continues."""
    fake_new_cli["devcontainer_rc"] = 1
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("n")            # decline seed
        await pilot.pause()
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0] is not None and not results[0].seed_devcontainer


async def test_uninspectable_devcontainer_continues(fake_client, fake_new_cli):
    fake_new_cli["devcontainer_rc"] = 2
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("enter")        # name (no confirm shown)
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0] is not None and not results[0].seed_devcontainer


async def test_unreachable_repo_aborts_with_none(fake_client, fake_new_cli):
    fake_new_cli["branches"] = (2, "")
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
    assert results == [None]


async def test_custom_name_is_sanitized(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("ctrl+u")       # clear the prefilled default
        await pilot.press("M", "y", "space", "R", "e", "p", "o",
                          "exclamation_mark")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].name == "my-repo"


async def test_blank_name_stays_on_name_step(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("ctrl+u")
        await pilot.press("enter")        # submit empty -> rejected
        await pilot.pause()
        assert app.screen.query("#wizard-name-input")
        # still usable: type a real name and finish
        await pilot.press("o", "k")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].name == "ok"


async def test_new_repo_option_opens_free_input(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("enter")        # "+ enter new…" is highlighted first
        await pilot.pause()
        repo_input = app.screen.query_one("#wizard-repo-input", Input)
        assert repo_input.has_focus
        await pilot.press("g", "h", "colon", "x", "slash", "y")
        await pilot.press("enter")
        await pilot.pause(0.2)
        assert fake_new_cli["calls"][0][-1] == "gh:x/y"
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    # line 1 of --list-branches output is the resolved URL and wins
    assert results[0].repo == "git@github.com:vossiman/alpha.git"


async def test_ide_ssh_can_be_selected(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("down")         # cursor -> ssh
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].ide == "ssh"


async def test_summary_decline_returns_to_ide_step(fake_client, fake_new_cli):
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")
        await pilot.pause(0.2)
        await pilot.press("enter")        # branch
        await pilot.pause(0.2)
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("n")            # decline summary
        await pilot.pause()
        assert results == []
        assert app.screen.query("#wizard-ide-list")
        await pilot.press("enter")        # ide again
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0] is not None


# ---- IDE default from the catalog ------------------------------------------


async def _drive_to_ide(pilot):
    """repo -> branch -> name, leaving the IDE OptionList on screen."""
    await pilot.press("down")
    await pilot.press("enter")            # repo
    await pilot.pause(0.2)
    await pilot.press("enter")            # branch
    await pilot.pause(0.2)
    await pilot.press("enter")            # accept default name
    await pilot.pause()


async def test_ide_step_preselects_catalog_default(fake_client, fake_new_cli):
    """Spec parity with the old gum wizard's `catalog_default ide`."""
    fake_client.defaults_body = {"ide": "ssh", "provider": "vossisrv"}
    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await _drive_to_ide(pilot)
        ide_list = app.screen.query_one("#wizard-ide-list", OptionList)
        assert ide_list.highlighted == 1                       # "ssh" row
        await pilot.press("enter")        # accept the preselected default
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].ide == "ssh"


async def test_ide_step_falls_back_to_cursor_when_catalog_fails(
    fake_client, fake_new_cli
):
    async def boom():
        raise RuntimeError("catalog down")

    fake_client.defaults = boom
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen())
        await pilot.pause()
        await _drive_to_ide(pilot)
        ide_list = app.screen.query_one("#wizard-ide-list", OptionList)
        assert ide_list.highlighted == 0                       # "cursor"


async def test_ide_step_ignores_unknown_catalog_default(fake_client,
                                                        fake_new_cli):
    fake_client.defaults_body = {"ide": "emacs"}
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen())
        await pilot.pause()
        await _drive_to_ide(pilot)
        assert app.screen.query_one("#wizard-ide-list",
                                    OptionList).highlighted == 0


# ---- stdout contract vs. stderr noise (real subprocess, no canned result) ---


async def test_branch_parse_ignores_stderr_noise(fake_client, tmp_path,
                                                 monkeypatch):
    """The wizard reads `dvw new --list-branches` STDOUT only.

    A real subprocess stands in for `dvw`: it dumps update-nudge / progress
    chatter to stderr and the contract (resolved URL, then branches) to
    stdout. With merged capture the first line would be noise and the
    resolved repo would be garbage.
    """
    fake_dvw = tmp_path / "dvw"
    fake_dvw.write_text(
        "#!/bin/sh\n"
        "echo '⬆ dvw is 3 behind main — run: dvw update' >&2\n"
        "echo '  › fetching branches for R…' >&2\n"
        "case \"$2\" in\n"
        "  --list-branches) printf 'git@github.com:vossiman/alpha.git\\nmain\\ndev\\n'; exit 0 ;;\n"
        "  --check-devcontainer) exit 0 ;;\n"
        "esac\n"
        "exit 1\n"
    )
    fake_dvw.chmod(0o755)
    monkeypatch.setenv("DVW_BIN", str(fake_dvw))

    app = DvwApp(client=fake_client)
    results = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(WizardScreen(), results.append)
        await pilot.pause()
        await pilot.press("down")
        await pilot.press("enter")        # repo -> real subprocess probe
        await pilot.pause(0.5)
        branch_list = app.screen.query_one("#wizard-branch-list", OptionList)
        assert [str(o.prompt) for o in branch_list.options] == ["main", "dev"]
        await pilot.press("enter")        # branch "main"
        await pilot.pause(0.5)
        await pilot.press("enter")        # name
        await pilot.pause()
        await pilot.press("enter")        # ide
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert results[0].repo == "git@github.com:vossiman/alpha.git"
    assert results[0].branch == "main"
