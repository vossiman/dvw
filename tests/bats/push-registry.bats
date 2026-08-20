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
  : > "$TMPDIR/dvw-ssh.live1/connected"
  printf 'ws-dead\n' > "$TMPDIR/dvw-ssh.dead1/workspace"
  printf '999999\n' > "$TMPDIR/dvw-ssh.dead1/pid"        # beyond pid_max default: dead
  : > "$TMPDIR/dvw-ssh.dead1/connected"
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
    : > "$TMPDIR/dvw-ssh.$d/connected"
  done
  run _dvw_push_live_sessions
  [ "$output" = "same-ws" ]
}

@test "live_sessions skips a session that never authenticated (no connected marker)" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.pending"
  printf 'ws-pending\n' > "$TMPDIR/dvw-ssh.pending/workspace"
  printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.pending/pid"
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live_sessions skips a live pid whose identity does not match (PID reuse)" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.reused"
  printf 'ws-reused\n' > "$TMPDIR/dvw-ssh.reused/workspace"
  printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.reused/pid"   # alive, but not the recorder
  : > "$TMPDIR/dvw-ssh.reused/connected"
  printf '1:1\n' > "$TMPDIR/dvw-ssh.reused/pid-start" # impossible starttime:uid
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live_sessions accepts a live pid with a matching identity token" {
  _load
  mkdir -p "$TMPDIR/dvw-ssh.same"
  printf 'ws-same\n' > "$TMPDIR/dvw-ssh.same/workspace"
  printf '%s\n' "$$" > "$TMPDIR/dvw-ssh.same/pid"
  : > "$TMPDIR/dvw-ssh.same/connected"
  _dvw_proc_identity "$$" > "$TMPDIR/dvw-ssh.same/pid-start"
  [ -s "$TMPDIR/dvw-ssh.same/pid-start" ]   # /proc must be readable here
  run _dvw_push_live_sessions
  [ "$status" -eq 0 ]
  [ "$output" = "ws-same" ]
}

@test "proc_identity is stable for a pid and differs across processes" {
  _load
  a=$(_dvw_proc_identity "$$")
  b=$(_dvw_proc_identity "$$")
  [ -n "$a" ]
  [ "$a" = "$b" ]
  sleep 5 &
  bg=$!
  c=$(_dvw_proc_identity "$bg")
  kill "$bg" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true
  [ -n "$c" ]
  [ "$a" != "$c" ]
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
  : > "$TMPDIR/dvw-ssh.race/connected"
  # Make pid unreadable to simulate TOCTOU race: file exists at -f check,
  # but becomes unreadable before read. Guards with `2>/dev/null || continue`
  # must handle this without breaking the rc 0 contract.
  chmod 000 "$TMPDIR/dvw-ssh.race/pid"
  run bash -c "set -euo pipefail; TMPDIR='$TMPDIR'; source '$DVW_ROOT/lib/push.sh'; _dvw_push_live_sessions"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- silent-boot window regression: the registry must never look live while
# --- no authenticated connection is up (initial connect, reconnect backoff).
# --- Each ssh stub snapshots _dvw_push_live_sessions at a precise moment in
# --- the session lifecycle; "connected" in a result spec means the stub
# --- honours LocalCommand, i.e. OpenSSH authenticated (ssh-reconnect.bats
# --- idiom).

_session_env() {
  _dvw_reap_stale_masters() { :; }
  _dvw_ssh_master_alive() { return 1; }
  export DVW_SSH_RECONNECT_DELAY=0
}

@test "initial connect window: session is not pushable before ssh authenticates" {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
# Auth in progress: LocalCommand deliberately NOT honoured. Snapshot the
# registry as a push arriving right now would see it.
source "$DVW_ROOT/lib/push.sh"
_dvw_push_live_sessions > "$TMPDIR/live-during-connect"
exit 255
EOF
  chmod +x "$STUB_BIN/ssh"
  _load
  _session_env
  run _dvw_ssh_session myws
  [ "$status" -eq 255 ]
  [ -f "$TMPDIR/live-during-connect" ]
  [ ! -s "$TMPDIR/live-during-connect" ]
}

@test "connected session is pushable while ssh is up" {
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in LocalCommand=*) eval "${a#LocalCommand=}" ;; esac; done
source "$DVW_ROOT/lib/push.sh"
_dvw_push_live_sessions > "$TMPDIR/live-during-session"
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  _load
  _session_env
  run _dvw_ssh_session myws
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/live-during-session")" = "myws" ]
}

@test "reconnect window: session is not pushable between drop and re-auth" {
  # Attempt 1 authenticates then loses transport (255); attempt 2 snapshots
  # the registry BEFORE honouring LocalCommand — exactly the backoff/retry
  # window a push must not trust — then reconnects cleanly.
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$TMPDIR/ssh-count" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$TMPDIR/ssh-count"
if [ "$count" -eq 1 ]; then
  for a in "$@"; do case "$a" in LocalCommand=*) eval "${a#LocalCommand=}" ;; esac; done
  exit 255
fi
source "$DVW_ROOT/lib/push.sh"
_dvw_push_live_sessions > "$TMPDIR/live-during-retry"
for a in "$@"; do case "$a" in LocalCommand=*) eval "${a#LocalCommand=}" ;; esac; done
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  _load
  _session_env
  run _dvw_ssh_session myws
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/ssh-count")" = "2" ]
  [ -f "$TMPDIR/live-during-retry" ]
  [ ! -s "$TMPDIR/live-during-retry" ]
}
