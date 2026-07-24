#!/usr/bin/env bats
#
# Interactive SSH retry behavior. The initial workspace/provider safety checks
# live in _connect_ssh; these tests isolate the post-check session runner so a
# reconnect can never accidentally enter a devpod-up path.
#
# SSH_RESULTS drives the ssh stub, one `rc[:seconds]` per attempt. The duration
# matters: the session runner only reconnects a session that actually ran, so a
# test that wants "established, then dropped" has to make the stub take at least
# DVW_SSH_MIN_SESSION_SECS. That threshold is lowered to 1s here to keep the
# sleeps short.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export SSH_CALLS="$TMPDIR/ssh-calls"
  export SSH_COUNT="$TMPDIR/ssh-count"
  export SSH_RESULTS="$TMPDIR/ssh-results"
  export REAP_CALLS="$TMPDIR/reap-calls"
  export DEVPOD_UP_CALLS="$TMPDIR/devpod-up-calls"
  : > "$SSH_CALLS"
  printf '0\n' > "$SSH_COUNT"
  : > "$REAP_CALLS"
  : > "$DEVPOD_UP_CALLS"
  export DVW_SSH_RECONNECT_DELAY=0
  export DVW_SSH_MIN_SESSION_SECS=1

  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$SSH_COUNT"
printf '%q ' "$@" >> "$SSH_CALLS"
printf '\n' >> "$SSH_CALLS"
spec=$(sed -n "${count}p" "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=0
[[ "${spec#*:}" != "$spec" ]] && sleep "${spec#*:}"
exit "${spec%%:*}"
EOF
  chmod +x "$STUB_BIN/ssh"

  ui_status_warn() { printf 'WARN: %s\n' "$*"; }
  ui_error() { printf 'ERROR: %s\n' "$*"; }
  ui_info() { printf 'INFO: %s\n' "$*"; }
  export -f ui_status_warn ui_error ui_info

  source "$DVW_ROOT/lib/connect.sh"

  _dvw_reap_stale_masters() { printf '%s\n' "$1" >> "$REAP_CALLS"; }
  _dvw_safe_devpod_up() {
    printf '%s\n' "$*" >> "$DEVPOD_UP_CALLS"
    return 99
  }
  export -f _dvw_reap_stale_masters _dvw_safe_devpod_up
}

teardown() { rm -rf "$TMPDIR"; }

@test "ssh session reconnects after transport loss and then returns cleanly" {
  printf '255:1\n0\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 2 ]
  [ "$(cat "$REAP_CALLS")" = "myws" ]
  [ ! -s "$DEVPOD_UP_CALLS" ]
  [[ "$output" == *"ssh transport lost"* ]]
  [[ "$output" == *"reconnecting in 0s"* ]]
}

@test "ssh session does not reconnect after clean detach or logout" {
  printf '0\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
}

@test "ssh session propagates non-transport remote command failure" {
  printf '42\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 42 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
}

@test "ssh session does not retry a connection that never established" {
  # An instant 255 is an auth/host-key/refused failure, not a dropped
  # transport. Reconnecting cannot fix it and would bury ssh's own error.
  printf '255\n255\n255\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
  [ ! -s "$DEVPOD_UP_CALLS" ]
  [[ "$output" == *"could not connect"* ]]
  [[ "$output" != *"reconnecting in"* ]]
}

@test "ssh session gives up after the reconnect budget instead of spinning" {
  # Established, then gone for good: a stopped container or a host that went
  # away. The loop must stop, not warn forever.
  printf '255:1\n255\n255\n255\n255\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=3

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 4 ]  # first session + 3 reconnect attempts
  [[ "$output" == *"still unreachable after 3 reconnect attempts"* ]]
  [[ "$output" == *"reconnect with: dvw myws"* ]]
  [ ! -s "$DEVPOD_UP_CALLS" ]
}

@test "each established session gets a fresh reconnect budget" {
  # drop, one failed retry, then a session that runs, then another drop: the
  # second drop must not inherit the first one's spent attempts.
  printf '255:1\n255\n255:1\n0\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=2

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 4 ]
  [[ "$output" != *"giving up"* ]]
  [[ "$output" != *"still unreachable"* ]]
}

@test "ssh session uses workspace alias and tmux work command" {
  printf '0\n' > "$SSH_RESULTS"

  run _dvw_ssh_session alpha

  [ "$status" -eq 0 ]
  run grep -F -- "-t alpha.devpod" "$SSH_CALLS"
  [ "$status" -eq 0 ]
  run grep -F -- "tmux new -A -D -s work" "$SSH_CALLS"
  [ "$status" -eq 0 ]
}

@test "reconnect delay backs off at one, two, then five seconds" {
  unset DVW_SSH_RECONNECT_DELAY

  [ "$(_dvw_ssh_reconnect_delay 0)" = "1" ]
  [ "$(_dvw_ssh_reconnect_delay 1)" = "2" ]
  [ "$(_dvw_ssh_reconnect_delay 2)" = "5" ]
  [ "$(_dvw_ssh_reconnect_delay 99)" = "5" ]
}
