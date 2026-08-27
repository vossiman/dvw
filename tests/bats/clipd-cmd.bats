#!/usr/bin/env bats
# cmd_clipd lifecycle: ensure (idempotent, stale-pid safe), status, stop.
# python3 stubbed on PATH with a fake daemon that binds nothing but creates
# the socket file and sleeps — lifecycle logic is what's under test, the real
# server has its own suite (clipd-server.bats).

bats_require_minimum_version 1.5.0

# python3 must be UNREACHABLE except via our stub: the "python3 missing"
# tests below delete the stub, and absence can't be faked while the real
# interpreter is still on PATH. See tests/bats/lib/sanitized-path.bash.
setup_file() {
  load "lib/sanitized-path.bash"
  sanitized_bin_init "$BATS_FILE_TMPDIR/sanitized-bin" python3
}

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$SANITIZED_BIN"
  cat > "$STUB_BIN/python3" <<'EOF'
#!/usr/bin/env bash
# fake dvw-clipd: record argv, create the socket path, then hang around
printf '%s\n' "$@" > "$HOME/python3-args"
sock=""
while (($#)); do [[ "$1" == "--socket" ]] && sock="$2"; shift; done
[[ -n "$sock" ]] && { mkdir -p "$(dirname "$sock")"; touch "$sock"; }
exec sleep 300
EOF
  chmod +x "$STUB_BIN/python3"
}

teardown() {
  if [[ -f "$HOME/.dvw/clipd.pid" ]]; then
    kill "$(cat "$HOME/.dvw/clipd.pid")" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}

_load() {
  ui_error() { printf 'ERR: %s\n' "$1"; }
  ui_info() { printf '%s\n' "$1"; }
  ui_status_ok() { printf 'OK: %s\n' "$1"; }
  ui_status_warn() { printf 'WARN: %s\n' "$1"; }
  source "$DVW_ROOT/lib/clipd.sh"
}

@test "clipd ensure: starts the daemon, writes pidfile, points it at ~/.dvw/clip.sock" {
  _load
  run -0 cmd_clipd ensure
  [[ -f "$HOME/.dvw/clipd.pid" ]]
  pid=$(cat "$HOME/.dvw/clipd.pid")
  kill -0 "$pid"
  grep -q -- "--socket" "$HOME/python3-args"
  grep -q "$HOME/.dvw/clip.sock" "$HOME/python3-args"
}

@test "clipd ensure: second call is a no-op (same pid)" {
  _load
  cmd_clipd ensure
  pid1=$(cat "$HOME/.dvw/clipd.pid")
  run -0 cmd_clipd ensure
  pid2=$(cat "$HOME/.dvw/clipd.pid")
  [[ "$pid1" == "$pid2" ]]
}

@test "clipd ensure: stale pidfile (dead pid) is replaced by a fresh daemon" {
  _load
  mkdir -p "$HOME/.dvw"
  echo 99999999 > "$HOME/.dvw/clipd.pid"
  run -0 cmd_clipd ensure
  pid=$(cat "$HOME/.dvw/clipd.pid")
  [[ "$pid" != 99999999 ]]
  kill -0 "$pid"
}

@test "clipd ensure: quiet failure when python3 is missing" {
  _load
  rm "$STUB_BIN/python3"
  hash -r
  run -1 cmd_clipd ensure
  [[ ! -f "$HOME/.dvw/clipd.pid" ]]
}

@test "clipd status: reports running with pid, and not-running after stop" {
  _load
  cmd_clipd ensure
  run -0 cmd_clipd status
  [[ "$output" == *running* ]]
  cmd_clipd stop
  run -0 cmd_clipd status
  [[ "$output" == *"not running"* ]]
}

@test "clipd stop: kills the daemon and removes pidfile and socket" {
  _load
  cmd_clipd ensure
  pid=$(cat "$HOME/.dvw/clipd.pid")
  run -0 cmd_clipd stop
  ! kill -0 "$pid" 2>/dev/null
  [[ ! -f "$HOME/.dvw/clipd.pid" ]]
  [[ ! -e "$HOME/.dvw/clip.sock" ]]
}

@test "clipd stop: no-op with friendly message when not running" {
  _load
  run -0 cmd_clipd stop
  [[ "$output" == *"not running"* ]]
}

@test "clipd ensure quiet helper: never fails the caller" {
  _load
  rm "$STUB_BIN/python3"
  hash -r
  run -0 _dvw_clipd_ensure_quiet
}

@test "dispatch: dvw clipd <sub> reaches cmd_clipd" {
  # dispatch.bats-style: source the entry script, stub pre-dispatch machinery.
  source "$DVW_ROOT/dvw"
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }
  cmd_clipd() { printf '%s\n' "$@" > "$TMPDIR/clipd-argv"; }
  main clipd status
  run -0 cat "$TMPDIR/clipd-argv"
  [[ "$output" == "status" ]]
}
