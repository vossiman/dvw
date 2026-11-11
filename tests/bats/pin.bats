#!/usr/bin/env bats
#
# Base-image helpers (lib/pin.sh) and cmd_recreate's use of them. All
# network access is stubbed.

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
}

@test "pin target is the floating :latest tag" {
  run _dvw_blueprint_pin
  [ "$output" = "ghcr.io/vossiman/devbox-base:latest" ]
}

@test "recreate pulls :latest on the provider before rebuilding" {
  _dvw_run_or_print() { echo "RUN $*"; }
  run _dvw_pull_latest
  [[ "$output" == *"ssh"*"vossisrv docker pull -q ghcr.io/vossiman/devbox-base:latest"* ]]
}

@test "id resolution: catalog discovery failure is not a silent success" {
  catalog_workspace_ids() { return 1; }
  run cmd_pin_rebuild
  [ "$status" -ne 0 ]
}

@test "id resolution: explicit ids are used verbatim, catalog untouched" {
  catalog_workspace_ids() { echo "SHOULD NOT RUN"; return 1; }
  run _dvw_pin_resolve_ids alpha beta
  [ "$status" -eq 0 ]
  [ "$output" = $'alpha\nbeta' ]
}

# WIRING: cmd_recreate calls `devpod up --recreate` directly, bypassing
# _dvw_safe_devpod_up. --configure-ssh defaults true, so the rebuild rewrites
# the stanza with `ForwardAgent yes`; without an explicit reconcile here every
# `dvw recreate` silently re-opens full-keyring agent forwarding.
_stub_recreate_deps() {
  _dvw_ensure_local_devpod_state()     { return 0; }
  _dvw_resolve_canonical_container()   { return 0; }
  _dvw_reap_stale_masters()            { :; }
  catalog_workspace_set_devpod_state() { :; }
  _dvw_run_or_print() { echo "ran:$*" >> "$BATS_TEST_TMPDIR/calls"; return "${UP_RC:-0}"; }
  _dvw_ensure_ssh_alias() { echo "reconciled:$1" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
}

@test "cmd_recreate: pulls :latest, then rebuilds and reconciles the ssh alias" {
  _stub_recreate_deps
  run cmd_recreate demo
  [ "$status" -eq 0 ]
  grep -q "ran:ssh .* docker pull -q ghcr.io/vossiman/devbox-base:latest" "$BATS_TEST_TMPDIR/calls"
  grep -q "ran:devpod up demo --recreate" "$BATS_TEST_TMPDIR/calls"
  grep -qx "reconciled:demo" "$BATS_TEST_TMPDIR/calls"
}

@test "cmd_recreate: does NOT reconcile when the rebuild failed" {
  _stub_recreate_deps
  UP_RC=1
  run cmd_recreate demo
  [ "$status" -ne 0 ]
  ! grep -q "reconciled:demo" "$BATS_TEST_TMPDIR/calls"
}

@test "dispatch: dvw pin-rebuild reaches cmd_pin_rebuild with its args" {
  cmd_pin_rebuild() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/argv"; }
  run main pin-rebuild demo other
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = $'demo\nother' ]
}

@test "dispatch: pin-sync is gone, not silently accepted" {
  run main pin-sync demo
  [ "$status" -ne 0 ]
}
