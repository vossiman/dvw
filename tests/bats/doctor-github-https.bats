#!/usr/bin/env bats
# cmd_doctor reports whether a github HTTPS git credential helper exists
# (warn-only). `devpod up` clones over HTTPS and resolves credentials by
# running `git credential fill` on this machine, so a client with SSH-only
# github auth can probe branches fine and still fail the workspace clone.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  export DVW_ROOT
  source "$DVW_ROOT/lib/ui.sh"
  source "$DVW_ROOT/lib/commands.sh"
  # Isolate git config so the host's real helpers never leak into the test.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  cd "$BATS_TEST_TMPDIR"   # outside any repo, so no local config either
}

@test "doctor github https check: helper configured -> OK line" {
  git config --global credential.https://github.com.helper '!gh auth git-credential'
  run _dvw_doctor_check_github_https
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]] && [[ "$output" == *"credential helper configured"* ]]
}

@test "doctor github https check: generic credential.helper also counts" {
  git config --global credential.helper 'store'
  run _dvw_doctor_check_github_https
  [ "$status" -eq 0 ]
}

@test "doctor github https check: no helper -> WARN with gh auth setup-git hint" {
  run _dvw_doctor_check_github_https
  [ "$status" -eq 1 ]
  [[ "$output" == *"[WARN]"* ]] && [[ "$output" == *"gh auth setup-git"* ]]
}
