from dvw_tui.wizard_names import DEVPOD_NAME_MAX, default_workspace_name


def test_default_name_is_leaf_dash_branch():
    assert default_workspace_name(
        "git@github.com:vossiman/alpha.git", "main") == "alpha-main"


def test_default_name_sanitizes_slashes_and_case():
    assert default_workspace_name(
        "https://github.com/v/Repo.git", "feat/New_Thing") == "repo-feat-new-thing"


def test_default_name_truncates_to_cap_without_trailing_dash():
    name = default_workspace_name(
        "git@github.com:v/devmachine-git.git", "design/dvw-extract-and-multi-agent")
    assert len(name) <= DEVPOD_NAME_MAX
    assert not name.endswith("-")


def test_default_name_local_path_repo():
    assert default_workspace_name("/tmp/fixtures/remote.git", "main") == "remote-main"
