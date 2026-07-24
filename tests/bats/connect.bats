#!/usr/bin/env bats
#
# cmd_connect mode selection: bare `dvw <id>` defaults to SSH (no gum
# chooser). Flags still force cursor/both/ssh.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export MODES_LOG="$BATS_TEST_TMPDIR/modes"
  : > "$MODES_LOG"
}

teardown() { rm -rf "$TMPDIR"; }

_load_connect() {
  ui_status_warn() { :; }
  ui_status_ok()   { :; }
  ui_info()        { :; }
  ui_error()       { echo "$*" >&2; }
  ui_action()      { :; }
  export -f ui_status_warn ui_status_ok ui_info ui_error ui_action

  source "$DVW_ROOT/lib/connect.sh"

  # Override after source — we only assert mode dispatch.
  _dvw_ensure_local_devpod_state() { :; }
  _dvw_ensure_ssh_alias() { :; }
  _dvw_resolve_canonical_container() { :; }
  _dvw_reap_stale_masters() { :; }
  _connect_ssh() { echo "ssh:$1" >> "$MODES_LOG"; }
  _connect_cursor() { echo "cursor:$1" >> "$MODES_LOG"; }
  export -f _dvw_ensure_local_devpod_state _dvw_ensure_ssh_alias \
    _dvw_resolve_canonical_container _dvw_reap_stale_masters \
    _connect_ssh _connect_cursor
}

@test "cmd_connect: bare id defaults to ssh (no gum)" {
  _load_connect
  # Poison gum — if the chooser were still called, this would fail loudly.
  cat > "$STUB_BIN/gum" <<'EOF'
#!/bin/bash
echo "gum should not be invoked for bare connect" >&2
exit 99
EOF
  chmod +x "$STUB_BIN/gum"

  run cmd_connect myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "ssh:myws" ]
}

@test "cmd_connect: --cursor invokes cursor only" {
  _load_connect
  run cmd_connect myws --cursor
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "cursor:myws" ]
}

@test "cmd_connect: --both invokes cursor then ssh" {
  _load_connect
  run cmd_connect myws --both
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "cursor:myws
ssh:myws" ]
}

@test "cmd_connect: --ssh invokes ssh" {
  _load_connect
  run cmd_connect myws --ssh
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "ssh:myws" ]
}
