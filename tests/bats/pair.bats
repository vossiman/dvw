#!/usr/bin/env bats
#
# cmd_pair (lib/connect.sh): paseo pairing that auto-heals the per-machine
# ssh alias + local devpod state before ssh-ing into the pod, so a workspace
# that has never been connected on THIS machine (only known via the catalog)
# is still pairable.
#
# These tests assert cmd_pair's orchestration — arg validation, call order,
# and that the pairing ssh is reached only after BOTH ensure-helpers succeed.
# The helpers themselves are stubbed here (covered by ssh-alias.bats); ssh is
# stubbed via PATH.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  # Non-socket catalog transport: any accidental service call fails fast. The
  # ensure-helpers are stubbed in every test that gets past arg validation, so
  # the real catalog path is never exercised here.
  export DVW_CATALOG_HOST=stub
  export DVW_CATALOG_SOCK="$TMPDIR/not-a-socket.sock"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"

  ui_error()       { echo "ERROR: $*" >&2; }
  ui_info()        { echo "INFO: $*" >&2; }
  ui_action()      { echo "ACTION: $*" >&2; }
  ui_status_ok()   { echo "OK: $*" >&2; }
  ui_status_warn() { echo "WARN: $*" >&2; }
  export -f ui_error ui_info ui_action ui_status_ok ui_status_warn

  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"

  # Each stage appends its name here so tests can assert sequencing.
  export ORDER_LOG="$TMPDIR/order.log"

  # ssh stub: record that it was reached + the argv it received.
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh" >> "$ORDER_LOG"
printf '%s\n' "\$@" > "$TMPDIR/ssh-argv"
EOF
  chmod +x "$STUB_BIN/ssh"
}

teardown() { rm -rf "$TMPDIR"; }

@test "cmd_pair: no id prints usage and fails without ssh" {
  run cmd_pair
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: dvw pair"* ]]
  [ ! -f "$TMPDIR/ssh-argv" ]
}

@test "cmd_pair: ensures local state, then ssh alias, then ssh — in that order" {
  _dvw_ensure_local_devpod_state() { echo "ensure_local" >> "$ORDER_LOG"; return 0; }
  _dvw_ensure_ssh_alias()          { echo "ensure_alias" >> "$ORDER_LOG"; return 0; }

  run cmd_pair myws
  [ "$status" -eq 0 ]
  [ "$(cat "$ORDER_LOG")" = "ensure_local
ensure_alias
ssh" ]
}

@test "cmd_pair: ssh targets <id>.devpod and runs the paseo pair helper" {
  _dvw_ensure_local_devpod_state() { return 0; }
  _dvw_ensure_ssh_alias()          { return 0; }

  run cmd_pair myws
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$TMPDIR/ssh-argv")" = "myws.devpod" ]
  [[ "$(sed -n '2p' "$TMPDIR/ssh-argv")" == *"aicoding-paseo-daemon pair"* ]]
}

@test "cmd_pair: aborts without ssh when local devpod state can't be materialized" {
  _dvw_ensure_local_devpod_state() { return 1; }
  _dvw_ensure_ssh_alias()          { echo "ensure_alias" >> "$ORDER_LOG"; return 0; }

  run cmd_pair myws
  [ "$status" -eq 1 ]
  [ ! -f "$TMPDIR/ssh-argv" ]
  # ssh-alias ensure must not run either once local state failed
  [ ! -f "$ORDER_LOG" ]
}

@test "cmd_pair: aborts without ssh when the ssh alias can't be registered" {
  _dvw_ensure_local_devpod_state() { return 0; }
  _dvw_ensure_ssh_alias()          { return 1; }

  run cmd_pair myws
  [ "$status" -eq 1 ]
  [ ! -f "$TMPDIR/ssh-argv" ]
}
