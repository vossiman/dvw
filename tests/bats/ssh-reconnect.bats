#!/usr/bin/env bats
#
# Interactive SSH retry behavior. The initial workspace/provider safety checks
# live in _connect_ssh; these tests isolate the post-check session runner so a
# reconnect can never accidentally enter a devpod-up path.
#
# SSH_RESULTS drives the ssh stub, one `rc[|log text]` per attempt (`\n` for
# multiple lines). The stub writes that text to the `-E` log file, which is where
# the retry decisions come from: a `debug1:` establishment marker is ssh's proof
# that the attempt reached a running session, and only that refills the budget.
# UP is that marker; DROPPED is an established session that then died.

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
log=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "-E" ]] && log="${args[i + 1]}"
done
spec=$(sed -n "${count}p" "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=$(tail -n1 "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=0
[[ "${SSH_SLEEP:-0}" != "0" ]] && sleep "$SSH_SLEEP"
text="${spec#*|}"
if [[ "$text" != "$spec" ]]; then
  if [[ -n "$log" ]]; then printf '%b\n' "$text" >> "$log"; else printf '%b\n' "$text" >&2; fi
fi
exit "${spec%%|*}"
EOF
  chmod +x "$STUB_BIN/ssh"

  # ssh's own establishment marker, and an established session that then died.
  UP='debug1: Authenticated to myws.devpod\ndebug1: Entering interactive session.'
  DROPPED="$UP"'\nConnection to myws.devpod closed by remote host.'
  REFUSED='ssh: connect to host myws.devpod port 22: Connection refused'

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
  printf '255|%s\n0\n' "$DROPPED" > "$SSH_RESULTS"

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
  printf '255|%s\n' "$REFUSED" > "$SSH_RESULTS"
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

@test "an established session that drops gets a fresh reconnect budget" {
  # drop, one failed retry, then a reconnect that establishes and drops again:
  # the second drop must not inherit the first one's spent attempts.
  {
    printf '255|%s\n' "$DROPPED"
    printf '255|%s\n' "$REFUSED"
    printf '255|%s\n' "$DROPPED"
    printf '0\n'
  } > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=2

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 4 ]
  [[ "$output" != *"still unreachable"* ]]
}

@test "a host that accepts and immediately closes cannot retry forever" {
  # Regression: an established-then-dropped attempt refills the per-streak
  # budget, so a host that keeps doing exactly that reset both the attempt count
  # and the deadline on every pass and reached neither limit. The total cap is
  # never reset, so it bounds the loop even when the refill signal keeps firing.
  printf '255|%s\n' "$DROPPED" > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_TOTAL_MAX=5
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=2
  export DVW_SSH_RECONNECT_MAX_SECONDS=1

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 6 ]  # first attempt + 5 reconnects, then the cap
  [[ "$output" == *"5 reconnects in one session without settling"* ]]
  [[ "$output" == *"reconnect with: dvw myws"* ]]
  [ ! -s "$DEVPOD_UP_CALLS" ]
}

@test "ssh diagnostics are replayed but verbose debug lines are not" {
  # One attempt whose log holds the `-v` banner, a debug line, and a real
  # diagnostic. Only the diagnostic is the user's business.
  printf '255|OpenSSH_9.6p1 Ubuntu-3ubuntu13.15, OpenSSL 3.0.13\\ndebug1: Connecting to myws.devpod\\n%s\n' \
    "$REFUSED" > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_MAX_ATTEMPTS=0

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [[ "$output" == *"Connection refused"* ]]
  [[ "$output" != *"debug1:"* ]]
  [[ "$output" != *"OpenSSH_9.6p1"* ]]
}

@test "ssh runs with a private verbose log so the pty stays clean" {
  printf '0\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  run grep -E -- "-v -E [^ ]*dvw-ssh-log" "$SSH_CALLS"
  [ "$status" -eq 0 ]
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
