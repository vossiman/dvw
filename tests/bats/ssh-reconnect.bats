#!/usr/bin/env bats
#
# Interactive SSH retry behavior. The initial workspace/provider safety checks
# live in _connect_ssh; these tests isolate the post-check session runner so a
# reconnect can never accidentally enter a devpod-up path.

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

  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$SSH_COUNT"
printf '%q ' "$@" >> "$SSH_CALLS"
printf '\n' >> "$SSH_CALLS"
result=$(sed -n "${count}p" "$SSH_RESULTS")
exit "${result:-0}"
EOF
  chmod +x "$STUB_BIN/ssh"

  ui_status_warn() { printf 'WARN: %s\n' "$*"; }
  export -f ui_status_warn

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
  printf '255\n0\n' > "$SSH_RESULTS"

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
