#!/usr/bin/env bats
#
# `dvw pin-rebuild`, the one-stop loop. Everything external is stubbed:
# catalog service, gh, devpod (via cmd_recreate). Follows pin-sync.bats.

setup() {
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
  command() { builtin command "$@"; }
  gh() { :; }   # presence check only; behavior stubbed per test

  # Defaults: current pin everywhere, everything succeeds.
  _dvw_catalog_source_get() {
    jq -n --arg p "$BP_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"main",
        committed_pin:$p, head:"deadbeef"}'
  }
  _dvw_catalog_source_pull() { _dvw_catalog_source_get "$1"; }
  cmd_recreate() { echo "RECREATED $1"; }
  _catalog_req() {  # step-8 inspect
    jq -n --arg d "sha256:$(printf 'a%.0s' {1..64})" '{image_digest:$d}'
  }
  DVW_PIN_REBUILD_POLL_SECS=0
}

@test "current pin: skips PR and pull, rebuilds anyway" {
  _dvw_catalog_source_pull() { echo "PULL SHOULD NOT RUN" >&2; return 1; }
  _dvw_pin_open_pr() { echo "OPEN_PR SHOULD NOT RUN" >&2; return 1; }
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }   # remote also current
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current"* ]]
  [[ "$output" != *"PULL SHOULD NOT RUN"* ]]
  [[ "$output" != *"OPEN_PR SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
  [[ "$output" == *"running the blueprint image"* ]]
}

@test "working tree current but remote stale: PR opened, merge gate, no pull, rebuild" {
  # aicoding's boot sync rewrites devcontainer.json in the container
  # uncommitted, so the common stale case has tree_pin == bp while the
  # remote branch still carries the old pin. This must still PR.
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }
  _dvw_catalog_source_pull() { echo "PULL SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull/9"* ]]
  [[ "$output" == *"merged: https://github.com/vossiman/demo/pull/9"* ]]
  [[ "$output" != *"PULL SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "working tree current, remote also current: skip PR and pull, rebuild" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  _dvw_pin_open_pr() { echo "OPEN_PR SHOULD NOT RUN" >&2; return 1; }
  _dvw_catalog_source_pull() { echo "PULL SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current"* ]]
  [[ "$output" != *"OPEN_PR SHOULD NOT RUN"* ]]
  [[ "$output" != *"PULL SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "working tree current, remote lookup fails: warn and skip PR, rebuild" {
  _dvw_repo_pin() { return 1; }
  _dvw_pin_open_pr() { echo "OPEN_PR SHOULD NOT RUN" >&2; return 1; }
  _dvw_catalog_source_pull() { echo "PULL SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't read main's remote pin"* ]]
  [[ "$output" == *"already current"* ]]
  [[ "$output" != *"OPEN_PR SHOULD NOT RUN"* ]]
  [[ "$output" != *"PULL SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "stale pin: PR, merge gate, pull, rebuild, verify" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"feat/x",
        committed_pin:$p, head:"deadbeef"}'
  }
  # Post-merge pull lands the blueprint pin (distinct from the pre-pull
  # _dvw_catalog_source_get stub above, which reflects the state before the
  # merge lands).
  _dvw_catalog_source_pull() {
    jq -n --arg p "$BP_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"feat/x",
        committed_pin:$p, head:"c0ffee"}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }   # pr view --jq .state
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull/9"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "stale pin with --no-wait: opens the PR and stops cleanly" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  run cmd_pin_rebuild demo --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" != *"RECREATED"* ]]
}

@test "pull that does not land the pin stops before the rebuild" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }
  _dvw_catalog_source_pull() {   # pull "succeeds" but pin unchanged
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pins"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "refused pull (dirty clone) is a hard stop naming the reason" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }
  _dvw_catalog_source_pull() {
    jq -n '{error:{code:"conflict", message:"source clone has uncommitted changes; refusing to pull over them"}}'
    return 1
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "detached clone is a hard stop" {
  _dvw_catalog_source_get() {
    jq -n '{present:true, detached:true, branch:null, committed_pin:null}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached"* ]]
}

@test "stale working-tree pin but remote branch already current: skips the PR, pulls, rebuilds" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"feat/x",
        committed_pin:$p, head:"deadbeef"}'
  }
  # A PR merged earlier landed the pin on the remote; the clone just hasn't
  # pulled it yet. _dvw_repo_pin reads the remote and already sees $BP_IMAGE.
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  _dvw_pin_open_pr() { echo "OPEN_PR SHOULD NOT RUN" >&2; return 1; }
  _dvw_pin_main_pr() { :; }
  _dvw_catalog_source_pull() {
    jq -n --arg p "$BP_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"feat/x",
        committed_pin:$p, head:"c0ffee"}'
  }
  gh() { echo "GH SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the PR"* ]]
  [[ "$output" != *"OPEN_PR SHOULD NOT RUN"* ]]
  [[ "$output" != *"GH SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "--timeout rejects non-numeric junk" {
  run cmd_pin_rebuild demo --timeout nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

@test "--timeout rejects a negative number" {
  run cmd_pin_rebuild demo --timeout -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

@test "closed-unmerged PR aborts with exit 2" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "CLOSED"; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 2 ]
}

@test "dry-run opens and mutates nothing" {
  export DVW_DRY_RUN=1
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "rebuild landing on the wrong image fails loudly" {
  _dvw_catalog_source_pull() { return 1; }   # unused: pin is current
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }   # remote also current
  _catalog_req() {
    jq -n --arg d "sha256:$(printf 'b%.0s' {1..64})" '{image_digest:$d}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"blueprint is"* ]]
}
