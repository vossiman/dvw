#!/usr/bin/env bats
#
# Session registry: _dvw_ssh_session records workspace+pid in its marker dir
# (lib/connect.sh); _dvw_push_live_sessions (lib/push.sh) enumerates marker
# dirs with a live pid. Writer test uses the attach.bats ssh-stub idiom: the
# stub runs while the session is "connected", so it can observe the registry
# files that the RETURN trap will remove afterwards.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
}

teardown() { rm -rf "$TMPDIR"; }

_load() {
  ui_error() { printf 'ERR: %s\n' "$1" >&2; }
  ui_info() { :; }; ui_status_warn() { :; }; ui_status_ok() { :; }
  source "$DVW_ROOT/lib/connect.sh"
  source "$DVW_ROOT/lib/push.sh"
}

@test "ssh session writes workspace and pid into its marker dir" {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
# Observe the registry while the session is live; the trap removes it later.
for a in "$@"; do case "$a" in LocalCommand=*) eval "${a#LocalCommand=}" ;; esac; done
cat "$TMPDIR"/dvw-ssh.*/workspace > "$TMPDIR/seen-ws"
cat "$TMPDIR"/dvw-ssh.*/pid > "$TMPDIR/seen-pid"
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  _load
  run _dvw_ssh_session myws
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/seen-ws")" = "myws" ]
  # pid is the dvw client process: numeric and alive at capture time
  [[ "$(cat "$TMPDIR/seen-pid")" =~ ^[0-9]+$ ]]
  # trap cleaned the marker dir afterwards
  run bash -c 'ls -d "$TMPDIR"/dvw-ssh.* 2>/dev/null'
  [ -z "$output" ]
}

@test "live_sessions lists workspaces whose pid is alive, skips dead" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.live1" "$TMPDIR/dvw-ssh.dead1"
  printf 'ws-alive\n' > "$TMPDIR/dvw-ssh.live1/workspace"
  printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.live1/pid"      # this bats process: alive
  printf 'ws-dead\n' > "$TMPDIR/dvw-ssh.dead1/workspace"
  printf '999999\n' > "$TMPDIR/dvw-ssh.dead1/pid"        # beyond pid_max default: dead
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ "$output" = "ws-alive" ]
}

@test "live_sessions dedupes the same workspace from two sessions" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.a" "$TMPDIR/dvw-ssh.b"
  for d in a b; do
    printf 'same-ws\n' > "$TMPDIR/dvw-ssh.$d/workspace"
    printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.$d/pid"
  done
  run _dvw_push_live_sessions
  [ "$output" = "same-ws" ]
}

@test "live_sessions is silent with no marker dirs" {
  _load
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live_sessions ignores marker dirs missing registry files (older dvw)" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.old"
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live_sessions tolerates unreadable pid files (race with marker cleanup)" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.race"
  printf 'ws-race\n' > "$TMPDIR/dvw-ssh.race/workspace"
  printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.race/pid"
  # Make pid unreadable to simulate TOCTOU race: file exists at -f check,
  # but becomes unreadable before read. Guards with `2>/dev/null || continue`
  # must handle this without breaking the rc 0 contract.
  chmod 000 "$TMPDIR/dvw-ssh.race/pid"
  run bash -c "set -euo pipefail; TMPDIR='$TMPDIR'; source '$DVW_ROOT/lib/push.sh'; _dvw_push_live_sessions"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
