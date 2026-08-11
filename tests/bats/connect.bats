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

# --- duplicate-container guard + action log -------------------------------
# 2026-07-26: two `devpod up` runs for one workspace produced sibling
# containers 6s apart. The survivors deadlocked connect, which refuses to pick
# between siblings without a tmux `work` session.

_load_up_guard() {
  _load_connect
  export DVW_UP_LOCK_DIR="$TMPDIR/locks"; mkdir -p "$DVW_UP_LOCK_DIR"
  export DVW_ACTION_LOG="$TMPDIR/actions.log"
  # No container on the provider -> the wipe guard permits `devpod up`.
  _dvw_provider_has_container() { return 1; }
  cat > "$STUB_BIN/devpod" <<'STUB'
#!/bin/bash
echo "devpod $*" >> "$MODES_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/devpod"
}

# A container already exists on the provider -> the wipe guard must gate
# `devpod up` behind ui_confirm (real implementation, not the earlier gum
# stubs). _load_connect only stubs ui_error/ui_info, so source ui.sh for a
# real ui_confirm.
_load_up_guard_container_exists() {
  _load_up_guard
  _dvw_provider_has_container() { return 0; }
  source "$DVW_ROOT/lib/ui.sh"
  export DVW_ASSUME_TTY=1
}

@test "_dvw_safe_devpod_up: wipe guard confirmed (y) runs devpod up" {
  _load_up_guard_container_exists
  run _dvw_safe_devpod_up myws --ide none <<< "y"
  [ "$status" -eq 0 ]
  grep -q "devpod up myws --ide none" "$MODES_LOG"
}

@test "_dvw_safe_devpod_up: wipe guard declined (n) aborts without running devpod up" {
  _load_up_guard_container_exists
  run _dvw_safe_devpod_up myws --ide none <<< "n"
  [ "$status" -ne 0 ]
  [ ! -s "$MODES_LOG" ]
}

@test "_dvw_safe_devpod_up: runs devpod up and releases the lock" {
  _load_up_guard
  run _dvw_safe_devpod_up myws --ide none
  [ "$status" -eq 0 ]
  grep -q "devpod up myws --ide none" "$MODES_LOG"
  # Lock must not leak, or every later run for this id is refused.
  [ -z "$(ls -A "$DVW_UP_LOCK_DIR")" ]
}

@test "_dvw_safe_devpod_up: refuses a second concurrent run for the same workspace" {
  _load_up_guard
  mkdir "$DVW_UP_LOCK_DIR/dvw-up-myws.lock"      # simulate a run in flight
  run _dvw_safe_devpod_up myws --ide none
  [ "$status" -ne 0 ]
  # The whole point: no second container.
  ! grep -q "devpod up myws" "$MODES_LOG"
}

@test "_dvw_safe_devpod_up: a different workspace is not blocked" {
  _load_up_guard
  mkdir "$DVW_UP_LOCK_DIR/dvw-up-myws.lock"
  run _dvw_safe_devpod_up otherws --ide none
  [ "$status" -eq 0 ]
  grep -q "devpod up otherws" "$MODES_LOG"
}

@test "_dvw_run_or_print: appends every mutating action to the action log" {
  _load_up_guard
  _dvw_run_or_print devpod up myws --ide none
  grep -q "devpod up myws --ide none" "$DVW_ACTION_LOG"
  grep -q "pid=" "$DVW_ACTION_LOG"
}

@test "_dvw_run_or_print: dry-run is logged but not executed, and takes no lock" {
  _load_up_guard
  DVW_DRY_RUN=1 run _dvw_safe_devpod_up myws --ide none
  [ "$status" -eq 0 ]
  [ ! -s "$MODES_LOG" ]                          # devpod never invoked
  [ -z "$(ls -A "$DVW_UP_LOCK_DIR")" ]           # --dry-run must not touch fs
}

@test "_dvw_log_action: a broken log path never fails the command" {
  _load_up_guard
  export DVW_ACTION_LOG=/proc/nonexistent/actions.log
  run _dvw_run_or_print devpod up myws
  [ "$status" -eq 0 ]
  grep -q "devpod up myws" "$MODES_LOG"
}

# --- single-initiator ordering --------------------------------------------
# 2026-08-09: on a COLD workspace, touching the <id>.devpod alias (probe or
# Cursor remote-ssh) fires DevPod's implicit `devpod up` via the ProxyCommand
# (`devpod ssh --stdio`, no flag to disable), racing our explicit up across
# the image pull — twin containers ~350µs apart. The per-id up-lock cannot
# see the implicit initiator, so ordering is the fix: when the catalog says
# "no container", up FIRST and only then open ssh/Cursor.

_load_order() {
  ui_status_warn() { :; }
  ui_status_ok()   { :; }
  ui_info()        { :; }
  ui_error()       { echo "$*" >&2; }
  ui_action()      { :; }
  export -f ui_status_warn ui_status_ok ui_info ui_error ui_action

  source "$DVW_ROOT/lib/connect.sh"

  _dvw_alias_defined() { return 0; }
  _dvw_safe_devpod_up() { echo "up:$1:${3:-}" >> "$MODES_LOG"; }
  _dvw_ssh_session() { echo "session:$1" >> "$MODES_LOG"; }
  _dvw_cursor_open() { echo "cursoropen:$1" >> "$MODES_LOG"; }
  _dvw_workspace_health() { echo "health:$1" >> "$MODES_LOG"; echo alive; }
  catalog_workspace_touch() { :; }
  catalog_workspace_set_devpod_state() { :; }
  export -f _dvw_alias_defined _dvw_safe_devpod_up _dvw_ssh_session \
    _dvw_cursor_open _dvw_workspace_health catalog_workspace_touch \
    catalog_workspace_set_devpod_state

  # Any `ssh` invocation is an alias touch — log it. Exit 0 = probe succeeds.
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/bin/bash
echo "sshprobe" >> "$MODES_LOG"
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
}

@test "_connect_ssh: cold workspace ups before any alias touch" {
  _load_order
  _dvw_ws_container_state() { echo no; }
  run _connect_ssh myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "up:myws:none
session:myws" ]
}

@test "_connect_ssh: warm workspace keeps probe-then-session, no up" {
  _load_order
  _dvw_ws_container_state() { echo yes; }
  run _connect_ssh myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "sshprobe
session:myws" ]
}

@test "_connect_ssh: catalog unreachable falls back to legacy probe path" {
  _load_order
  _dvw_ws_container_state() { echo unknown; }
  run _connect_ssh myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "sshprobe
session:myws" ]
}

@test "_connect_cursor: cold workspace ups before health check or open" {
  _load_order
  _dvw_ws_container_state() { echo no; }
  run _connect_cursor myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "up:myws:cursor" ]
}

@test "_connect_cursor: warm workspace keeps health-then-open" {
  _load_order
  _dvw_ws_container_state() { echo yes; }
  run _connect_cursor myws
  [ "$status" -eq 0 ]
  [ "$(cat "$MODES_LOG")" = "health:myws
cursoropen:myws" ]
}

# --- non-catalog id guard --------------------------------------------------
# 2026-08-09: a workspace purged from the catalog but still in the local
# DevPod registry ("zombie") stayed dvw-selectable and up-able. `devpod up`
# on such an id resurrects it. Refuse: the catalog is the authority.

@test "_dvw_safe_devpod_up: refuses an id absent from the catalog" {
  _load_up_guard
  catalog_workspace_ids() { printf 'realws\n'; }
  run _dvw_safe_devpod_up zombiews --ide none
  [ "$status" -ne 0 ]
  ! grep -q "devpod up zombiews" "$MODES_LOG"
}

@test "_dvw_safe_devpod_up: catalog-listed id proceeds" {
  _load_up_guard
  catalog_workspace_ids() { printf 'myws\nrealws\n'; }
  run _dvw_safe_devpod_up myws --ide none
  [ "$status" -eq 0 ]
  grep -q "devpod up myws --ide none" "$MODES_LOG"
}

@test "_dvw_safe_devpod_up: empty/unreachable catalog fails open" {
  _load_up_guard
  catalog_workspace_ids() { return 1; }
  run _dvw_safe_devpod_up myws --ide none
  [ "$status" -eq 0 ]
  grep -q "devpod up myws --ide none" "$MODES_LOG"
}
