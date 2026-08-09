#!/usr/bin/env bats
#
# `dvw attach` — jump to the tmux window most recently flagged @waiting by
# agent-notify. Consumes GET /v1/containers/waiting (sorted newest-first by
# the service) and either connects straight in (0 or 1 waiting) or opens a
# picker (>1).
#
# Two layers are exercised:
#   - cmd_attach's own count/format logic — cmd_connect stubbed out, mirroring
#     how connect.bats stubs _connect_ssh/_connect_cursor to isolate mode
#     dispatch from the actual ssh/cursor mechanics.
#   - The full chain down to the ssh argv (cmd_connect -> _connect_ssh ->
#     _dvw_ssh_session) for the one-waiting and malformed-window-id cases,
#     since that's where window-id validation before embedding actually
#     lives (lib/connect.sh, not commands.sh) — same boundary
#     ssh-reconnect.bats uses to test _dvw_ssh_session directly.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export SSH_ARGS="$HOME/ssh-args"
  : > "$SSH_ARGS"
}

teardown() { rm -rf "$TMPDIR"; }

# ssh stub for the full-chain tests: always "connects" (rc 0, honours
# LocalCommand like a real authenticated session), and records every arg it
# was called with — one per line, so a multi-line remote_command string is
# still greppable as a substring rather than mangled by %q re-quoting.
_install_ssh_stub() {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  printf '%s\n' "$a" >> "$SSH_ARGS"
  case "$a" in
    LocalCommand=*) eval "${a#LocalCommand=}" ;;
  esac
done
printf '===END===\n' >> "$SSH_ARGS"
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
}

_load_attach() {
  ui_status_warn() { :; }
  ui_status_ok()   { :; }
  ui_info()        { printf 'INFO: %s\n' "$*"; }
  ui_error()       { printf 'ERROR: %s\n' "$*" >&2; }
  ui_action()      { :; }
  ui_top_menu()    { echo "TOP_MENU_CALLED"; return "${TOP_MENU_RC:-0}"; }
  export -f ui_status_warn ui_status_ok ui_info ui_error ui_action ui_top_menu

  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  source "$DVW_ROOT/lib/commands.sh"

  # Pre-flight/alignment helpers cmd_connect chains through before the ssh
  # session — already covered by connect.bats/resolver.bats, no-op them here
  # so attach.bats stays focused on attach's own logic + the window-id path.
  _dvw_ensure_local_devpod_state() { :; }
  _dvw_ensure_ssh_alias() { :; }
  _dvw_resolve_canonical_container() { :; }
  _dvw_reap_stale_masters() { :; }
  export -f _dvw_ensure_local_devpod_state _dvw_ensure_ssh_alias \
    _dvw_resolve_canonical_container _dvw_reap_stale_masters
}

# Serve fixed JSON from GET /v1/containers/waiting; every other route is a
# transport failure (rc 2, empty body) — matches how a real unreachable/
# unrelated call behaves, and attach only ever touches this one route plus
# whatever cmd_connect's own catalog calls do (which are no-ops here).
_serve_waiting() {
  # A `local` here would vanish once this function returns, leaving the
  # _catalog_req closure below reading an unset variable the moment
  # cmd_attach actually calls it — global on purpose.
  WAITING_BODY="$1"
  _catalog_req() {
    if [[ "$1 $2" == "GET /v1/containers/waiting" ]]; then
      printf '%s' "$WAITING_BODY"
      return 0
    fi
    return 2
  }
  export -f _catalog_req
}

@test "attach with one waiting window connects with select-window chained" {
  _load_attach
  _install_ssh_stub
  _serve_waiting '[{"workspace_id":"devmachine","container_id":"c1","window_id":"@7","window_name":"work","waiting_since":1754700000}]'
  run cmd_attach
  [ "$status" -eq 0 ]
  grep -q "select-window -t '@7'" "$SSH_ARGS"
}

@test "attach validates window id before embedding" {
  _load_attach
  _install_ssh_stub
  _serve_waiting '[{"workspace_id":"devmachine","container_id":"c1","window_id":"; rm -rf /","window_name":"work","waiting_since":1754700000}]'
  run cmd_attach
  ! grep -q "rm -rf" "$SSH_ARGS"
}

@test "attach with nothing waiting reports and falls through to menu" {
  _load_attach
  _serve_waiting '[]'
  run cmd_attach
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'nothing waiting'
  echo "$output" | grep -q 'TOP_MENU_CALLED'
}

@test "attach with multiple waiting windows opens a picker, newest-first row wins" {
  _load_attach
  export CONNECT_LOG="$HOME/connect-log"
  : > "$CONNECT_LOG"
  cmd_connect() { printf '%s\n' "$*" > "$CONNECT_LOG"; }
  export -f cmd_connect
  _serve_waiting '[
    {"workspace_id":"newws","container_id":"c2","window_id":"@9","window_name":"newer","waiting_since":2000},
    {"workspace_id":"oldws","container_id":"c1","window_id":"@3","window_name":"older","waiting_since":1000}
  ]'
  cat > "$STUB_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
head -n1
EOF
  chmod +x "$STUB_BIN/fzf"
  run cmd_attach
  [ "$status" -eq 0 ]
  grep -q "^newws " "$CONNECT_LOG"
  grep -q '@9' "$CONNECT_LOG"
  ! grep -q 'oldws' "$CONNECT_LOG"
}

@test "dispatch: dvw attach reaches cmd_attach" {
  source "$DVW_ROOT/dvw"
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }
  cmd_attach() { echo "cmd_attach called with: $*" > "$BATS_TEST_TMPDIR/attach-argv"; }

  run main attach
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/attach-argv")" = "cmd_attach called with: " ]
}
