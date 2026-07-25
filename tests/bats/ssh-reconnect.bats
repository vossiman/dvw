#!/usr/bin/env bats
#
# Interactive SSH retry behavior. The initial workspace/provider safety checks
# live in _connect_ssh; these tests isolate the post-check session runner so a
# reconnect can never accidentally enter a devpod-up path.
#
# SSH_RESULTS drives the ssh stub, one `rc[|stderr text]` per attempt. The
# stderr text is what the retry decisions key off: ssh distinguishes "could not
# connect", "was connected and dropped", and "auth/config is wrong" in its own
# messages, and the loop classifies those rather than guessing from timing.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export SSH_CALLS="$TMPDIR/ssh-calls"
  export SSH_COUNT="$TMPDIR/ssh-count"
  export SSH_RESULTS="$TMPDIR/ssh-results"
  export SSH_SLEEP="${SSH_SLEEP:-0}"
  export REAP_CALLS="$TMPDIR/reap-calls"
  export DEVPOD_UP_CALLS="$TMPDIR/devpod-up-calls"
  : > "$SSH_CALLS"
  printf '0\n' > "$SSH_COUNT"
  : > "$REAP_CALLS"
  : > "$DEVPOD_UP_CALLS"
  export DVW_SSH_RECONNECT_DELAY=0

  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$SSH_COUNT"
printf '%q ' "$@" >> "$SSH_CALLS"
printf '\n' >> "$SSH_CALLS"
spec=$(sed -n "${count}p" "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=$(tail -n1 "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=0
[[ "${SSH_SLEEP:-0}" != "0" ]] && sleep "$SSH_SLEEP"
[[ "${spec#*|}" != "$spec" ]] && printf '%s\n' "${spec#*|}" >&2
exit "${spec%%|*}"
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
  printf '255|client_loop: send disconnect: Broken pipe\n0\n' > "$SSH_RESULTS"

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

@test "ssh session does not retry an auth or host-key failure" {
  # Reconnecting cannot fix these, and retrying would bury ssh's own message.
  printf '255|Host key verification failed.\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
  [[ "$output" == *"Host key verification failed."* ]]  # replayed, not swallowed
  [[ "$output" == *"reconnecting cannot fix"* ]]
  [[ "$output" != *"reconnecting in"* ]]
}

@test "ssh session does not retry a permission-denied failure" {
  printf '255|Permission denied (publickey).\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [[ "$output" == *"reconnecting cannot fix"* ]]
}

@test "ssh session gives up after the attempt budget instead of spinning" {
  printf '255|ssh: connect to host myws.devpod port 22: Connection refused\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=3

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 4 ]  # first attempt + 3 reconnects
  [[ "$output" == *"still unreachable"* ]]
  [[ "$output" == *"reconnect with: dvw myws"* ]]
  [ ! -s "$DEVPOD_UP_CALLS" ]
}

@test "a failure to connect never refills the reconnect budget" {
  # Regression: a slow connect failure used to look like a long, successful
  # session, refill the budget on every attempt, and leave the loop unbounded
  # against a host that was never coming back.
  export SSH_SLEEP=1
  printf '255|ssh: connect to host myws.devpod port 22: Connection timed out\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=2

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 3 ]
  [[ "$output" == *"still unreachable"* ]]
}

@test "a retry streak also stops on the wall-clock deadline" {
  # Attempts that each block for a TCP timeout blow the time budget long before
  # the attempt count, so the deadline is the bound that actually applies.
  export SSH_SLEEP=1
  printf '255|ssh: connect to host myws.devpod port 22: Connection timed out\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=99
  export DVW_SSH_RECONNECT_MAX_SECONDS=2

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -lt 10 ]
  [[ "$output" == *"still unreachable"* ]]
}

@test "a reported disconnect gets a fresh reconnect budget" {
  # drop, one failed retry, then another reported drop: the second must not
  # inherit the first one's spent attempts.
  {
    printf '255|client_loop: send disconnect: Broken pipe\n'
    printf '255|ssh: connect to host myws.devpod port 22: Connection refused\n'
    printf '255|Connection to myws.devpod closed by remote host.\n'
    printf '0\n'
  } > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=2

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 4 ]
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
