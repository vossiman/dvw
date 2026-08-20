#!/usr/bin/env bats
#
# `dvw pin-sync` and the rebuild pre-flight.
#
# Context: aicoding-sync rewrites .devcontainer/devcontainer.json in the
# container working tree but never commits it, so repo copies drift and
# `devpod up --recreate` (which builds from the COMMITTED pin) reinstalls the
# stale image. These tests pin the classification and the offer-before-rebuild
# behavior. All GitHub/network access is stubbed — no gh, no curl.

setup() {
  # Plain source on purpose — see the note in dispatch.bats about set +o and
  # bats' ERR trap.
  source "$DVW_ROOT/dvw"

  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  BP_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'a%.0s' {1..64})"
  OLD_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'b%.0s' {1..64})"
  export BP_IMAGE OLD_IMAGE

  _dvw_blueprint_pin() { printf '%s\n' "$BP_IMAGE"; }
  catalog_workspace_get() {
    jq -n --arg r "git@github.com:vossiman/demo.git" --arg b main \
      '{repo:$r, branch:$b, ide:"ssh"}'
  }
  catalog_workspace_ids() { printf 'demo\n'; }
  command() { builtin command "$@"; }   # real lookups unless overridden below
}

@test "pin state: repo pin equal to the blueprint is ok" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == ok$'\t'vossiman/demo$'\t'main* ]]
}

@test "pin state: an older digest is stale" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == stale$'\t'vossiman/demo$'\t'main* ]]
}

@test "pin state: a repo with no devcontainer image is 'none', not stale" {
  _dvw_repo_pin() { printf '\n'; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == none$'\t'* ]]
}

@test "repo slug: both remote forms the fleet uses resolve to owner/name" {
  run _dvw_repo_slug "git@github.com:vossiman/demo.git"
  [ "$output" = "vossiman/demo" ]
  run _dvw_repo_slug "https://github.com/vossiman/demo"
  [ "$output" = "vossiman/demo" ]
}

@test "repo slug: a non-GitHub remote is refused (the gh PR path can't serve it)" {
  run _dvw_repo_slug "https://gitlab.com/vossiman/demo.git"
  [ "$status" -ne 0 ]
}

@test "pin-sync: a stale workspace gets a PR opened" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  _dvw_pin_open_pr() { printf 'https://github.com/%s/pull/1\n' "$1"; }
  run cmd_pin_sync demo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "stale"
  echo "$output" | grep -q "https://github.com/vossiman/demo/pull/1"
}

@test "pin-sync: a current workspace opens nothing" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  _dvw_pin_open_pr() { echo "SHOULD NOT RUN"; return 1; }
  run cmd_pin_sync demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT RUN"
  echo "$output" | grep -q "already at"
}

@test "rebuild pre-flight: a current pin passes straight through" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  ui_confirm() { echo "SHOULD NOT ASK"; return 0; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT ASK"
}

@test "rebuild pre-flight: a stale pin OFFERS pin-sync and aborts when accepted" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { return 0; }          # user says yes
  cmd_pin_sync() { echo "PIN SYNC RAN"; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 1 ]                 # non-zero = cmd_recreate skips the rebuild
  echo "$output" | grep -q "PIN SYNC RAN"
}

@test "rebuild pre-flight: declining the offer proceeds with the rebuild" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { return 1; }          # user says no
  cmd_pin_sync() { echo "SHOULD NOT RUN"; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]                 # zero = cmd_recreate goes ahead
  ! echo "$output" | grep -q "SHOULD NOT RUN"
}

@test "rebuild pre-flight: no gh CLI means silent pass-through, never a block" {
  command() { if [ "$2" = gh ]; then return 1; fi; builtin command "$@"; }
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { echo "SHOULD NOT ASK"; return 0; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT ASK"
}

@test "dispatch: dvw pin-sync reaches cmd_pin_sync with its args" {
  cmd_pin_sync() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/argv"; }
  run main pin-sync demo
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = "demo" ]
}
