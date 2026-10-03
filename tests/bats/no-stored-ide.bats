#!/usr/bin/env bats
#
# Legacy catalog entries can still carry `"ide": "cursor"`. Start and rebuild
# must ignore it and always run `devpod up --ide none`; Cursor is per connect.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  source "$DVW_ROOT/dvw"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  catalog_workspace_get() { printf '{"id":"%s","repo":"r","branch":"main","ide":"cursor"}\n' "$1"; }
  catalog_workspace_set_devpod_state() { :; }
  _dvw_ensure_local_devpod_state() { :; }
  _dvw_ensure_ssh_alias() { :; }
  _dvw_resolve_canonical_container() { :; }
  _dvw_reap_stale_masters() { :; }
  _dvw_load_probe() { declare -gA DVW_PROBE_STATE=([legacy]=stopped); }
  _dvw_blueprint_pin() { echo pin; }
  _dvw_pull_latest() { :; }
  _dvw_safe_devpod_up() { echo "up $*" >> "$CALLS"; }
  _dvw_run_or_print() { echo "$*" >> "$CALLS"; }
}

@test "start ignores a legacy stored cursor IDE" {
  run cmd_start legacy
  [ "$status" -eq 0 ]
  grep -qx "up legacy --ide none" "$CALLS"
}

@test "recreate ignores a legacy stored cursor IDE" {
  DVW_SKIP_PIN_PREFLIGHT=1 run cmd_recreate legacy
  [ "$status" -eq 0 ]
  grep -qx "devpod up legacy --recreate --ide none" "$CALLS"
  ! grep -q cursor "$CALLS"
}
