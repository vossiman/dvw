#!/usr/bin/env bats
#
# `dvw pin-rebuild`: recreate onto :latest, then assert image_current.
# The catalog and devpod (via cmd_recreate) are stubbed.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  source "$DVW_ROOT/dvw"
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  catalog_workspace_get() {
    jq -n --arg r "git@github.com:vossiman/demo.git" '{repo:$r, branch:"main"}'
  }
  cmd_recreate() { echo "RECREATED $1"; }
  _catalog_req() { jq -n '{image_current:true}'; }
}

@test "rebuilds and verifies the newest image" {
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECREATED demo"* ]]
  [[ "$output" == *"running the newest image"* ]]
}

@test "needs neither gh nor the catalog source API" {
  command() {
    [[ "$1" == -v && "$2" == gh ]] && return 1
    builtin command "$@"
  }
  _catalog_req() {
    [[ "$2" == */source* ]] && { echo "SOURCE API SHOULD NOT BE CALLED" >&2; return 1; }
    jq -n '{image_current:true}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT"* ]]
}

@test "rebuild landing on the wrong image fails loudly" {
  _catalog_req() { jq -n '{image_current:false}'; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on the newest image"* ]]
}

@test "an unverifiable image warns but does not fail" {
  _catalog_req() { return 2; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't verify demo's image"* ]]
}

@test "a failed recreate fails and skips the check" {
  cmd_recreate() { return 1; }
  _catalog_req() { echo "CHECK SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" != *"CHECK SHOULD NOT RUN"* ]]
}

@test "unknown workspace is refused before any rebuild" {
  catalog_workspace_get() { return 1; }
  run cmd_pin_rebuild nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown workspace: nope"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "dry-run rebuilds nothing" {
  export DVW_DRY_RUN=1
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "removed flags are rejected, not silently ignored" {
  local f
  for f in --pr-only --no-wait --timeout; do
    run cmd_pin_rebuild demo "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag: $f"* ]]
  done
}

@test "no ids: runs the whole catalog, one workspace at a time" {
  catalog_workspace_ids() { printf 'alpha\nbeta\n'; }
  _dvw_pin_rebuild_one() { echo "ONE:$1"; }
  run cmd_pin_rebuild
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONE:alpha"* ]]
  [[ "$output" == *"ONE:beta"* ]]
}

@test "one failing workspace fails the run but the others still rebuild" {
  catalog_workspace_ids() { printf 'alpha\nbeta\n'; }
  _dvw_pin_rebuild_one() { echo "ONE:$1"; [[ "$1" != alpha ]]; }
  run cmd_pin_rebuild
  [ "$status" -eq 1 ]
  [[ "$output" == *"ONE:beta"* ]]
}
