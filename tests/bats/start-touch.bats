#!/usr/bin/env bats
#
# cmd_start tells the catalog first, so an idle countdown cannot stop the
# workspace it is about to report as running.

setup() {
  source "$DVW_ROOT/dvw"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  _dvw_ensure_local_devpod_state() { echo "state:$1" >> "$CALLS"; }
  _dvw_ensure_ssh_alias() { :; }
  _dvw_resolve_canonical_container() { :; }
  _dvw_reap_stale_masters() { :; }
  _dvw_load_probe() { declare -gA DVW_PROBE_STATE=([w1]=alive); }
  catalog_workspace_touch() { echo "touch:$1" >> "$CALLS"; }
}

@test "cmd_start touches the catalog before anything else" {
  run cmd_start w1
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "touch:w1" ]
}

@test "cmd_start warns when the touch fails and still proceeds" {
  catalog_workspace_touch() { return 1; }
  run cmd_start w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"automatic stop"* ]]
  grep -q "state:w1" "$CALLS"
}
