#!/usr/bin/env bats
# _dvw_push_resolve_target: live-session detection (one/many/none) and --to
# pass-through, plus the _dvw_push_require_running catalog gate that cmd_push
# applies to every resolved target. Catalog stubbed via
# _dvw_ws_container_state override; sessions stubbed via
# _dvw_push_live_sessions override; picker exercised in numbered-list mode
# (PATH without fzf), non-tty guarded by DVW_ASSUME_TTY.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export PATH="/usr/bin:/bin"   # no fzf: forces the numbered-list fallback
}

teardown() { rm -rf "$TMPDIR"; }

_load() {
  ERRS="$TMPDIR/errs"; : > "$ERRS"
  ui_error() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_info() { :; }
  source "$DVW_ROOT/lib/push.sh"
}

@test "one live session resolves to it" {
  _load
  _dvw_push_live_sessions() { printf 'onlyws\n'; }
  run _dvw_push_resolve_target
  [ "$status" -eq 0 ]
  [ "$output" = "onlyws" ]
}

@test "no live session errors and suggests --to" {
  _load
  _dvw_push_live_sessions() { :; }
  run _dvw_push_resolve_target
  [ "$status" -eq 1 ]
  run grep -q -- '--to' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "several live sessions: numbered picker selects" {
  _load
  _dvw_push_live_sessions() { printf 'ws-a\nws-b\n'; }
  # 2>/dev/null: the numbered list + "push to #> " prompt go to stderr; a
  # combined capture would jam the promptless line onto the result.
  DVW_ASSUME_TTY=1 run bash -c '
    source "$DVW_ROOT/lib/push.sh"
    ui_error() { :; }; ui_info() { :; }
    _dvw_push_live_sessions() { printf "ws-a\nws-b\n"; }
    _dvw_push_resolve_target <<< "2" 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "ws-b" ]
}

@test "several live sessions non-interactively demands --to" {
  _load
  _dvw_push_live_sessions() { printf 'ws-a\nws-b\n'; }
  run _dvw_push_resolve_target < /dev/null
  [ "$status" -eq 1 ]
  run grep -q -- '--to' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "--to resolves to the given name without consulting the catalog" {
  _load
  # The RUNNING gate is cmd_push's job (once, for every path); resolution
  # must not double-charge the catalog transport for it.
  _dvw_ws_container_state() { echo consulted > "$TMPDIR/state-called"; echo no; }
  run _dvw_push_resolve_target explicitws
  [ "$status" -eq 0 ]
  [ "$output" = "explicitws" ]
  [ ! -e "$TMPDIR/state-called" ]
}

@test "require_running passes a RUNNING workspace" {
  _load
  _dvw_ws_container_state() { echo yes; }
  run _dvw_push_require_running explicitws
  [ "$status" -eq 0 ]
}

@test "require_running refuses a stopped workspace (auto-up footgun)" {
  _load
  _dvw_ws_container_state() { echo no; }
  run _dvw_push_require_running stoppedws
  [ "$status" -eq 1 ]
  run grep -q 'not running' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "require_running with catalog unreachable refuses, not guesses" {
  _load
  _dvw_ws_container_state() { echo unknown; }
  run _dvw_push_require_running somews
  [ "$status" -eq 1 ]
  run grep -qi 'catalog' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "fzf cancellation (Esc) emits error and returns nonzero" {
  _load
  # Create stub fzf that simulates Esc (exit 130)
  local bindir="$TMPDIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/fzf" <<'FZFSTUB'
#!/bin/bash
exit 130
FZFSTUB
  chmod +x "$bindir/fzf"

  # Prepend bindir to PATH so our stub fzf is found
  export PATH="$bindir:/usr/bin:/bin"

  _dvw_push_live_sessions() { printf 'ws-a\nws-b\n'; }
  run _dvw_push_resolve_target
  [ "$status" -ne 0 ]
  run grep -q 'selection cancelled' "$ERRS"
  [ "$status" -eq 0 ]
}
