#!/usr/bin/env bats
#
# Interactive SSH retry behavior. The initial workspace/provider safety checks
# live in _connect_ssh; these tests isolate the post-check session runner so a
# reconnect can never accidentally enter a devpod-up path.
#
# SSH_RESULTS drives the ssh stub, one `rc[|connected]` per attempt. `connected`
# makes the stub honour the `-o LocalCommand=touch <marker>` it was passed,
# which is how OpenSSH signals that a connection authenticated — the stub is
# mimicking the real hook, verified against a live sshd in
# scratchpad/verify-localcommand.sh (11 checks, including a real transport cut).

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
localcmd=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == LocalCommand=* ]] && localcmd="${args[i]#LocalCommand=}"
done
spec=$(sed -n "${count}p" "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=$(tail -n1 "$SSH_RESULTS")
[[ -n "$spec" ]] || spec=0
[[ "${SSH_SLEEP:-0}" != "0" ]] && sleep "$SSH_SLEEP"
# "connected" == OpenSSH ran the client-side hook after authenticating.
[[ "${spec#*|}" == "connected" && -n "$localcmd" ]] && eval "$localcmd"
exit "${spec%%|*}"
EOF
  chmod +x "$STUB_BIN/ssh"

  ui_status_warn() { printf 'WARN: %s\n' "$*"; }
  ui_error() { printf 'ERROR: %s\n' "$*"; }
  ui_info() { printf 'INFO: %s\n' "$*"; }
  export -f ui_status_warn ui_error ui_info

  source "$DVW_ROOT/lib/connect.sh"

  _dvw_reap_stale_masters() { printf '%s\n' "$1" >> "$REAP_CALLS"; }
  # No multiplex master unless a test says otherwise.
  _dvw_ssh_master_alive() { return 1; }
  _dvw_safe_devpod_up() {
    printf '%s\n' "$*" >> "$DEVPOD_UP_CALLS"
    return 99
  }
  export -f _dvw_reap_stale_masters _dvw_ssh_master_alive _dvw_safe_devpod_up
}

teardown() { rm -rf "$TMPDIR"; }

@test "ssh session reconnects after transport loss and then returns cleanly" {
  printf '255|connected\n0|connected\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 2 ]
  [ "$(cat "$REAP_CALLS")" = "myws" ]
  [ ! -s "$DEVPOD_UP_CALLS" ]
  [[ "$output" == *"ssh transport lost"* ]]
  [[ "$output" == *"reconnecting in 0s"* ]]
}

@test "ssh session does not reconnect after clean detach or logout" {
  printf '0|connected\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
}

@test "ssh session propagates non-transport remote command failure" {
  printf '42|connected\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 42 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
}

@test "ssh session does not retry when it never connected" {
  # No hook fired: auth, host key, config, or an unreachable host. There is no
  # session to reattach to, and retrying would bury ssh's own error.
  printf '255\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 1 ]
  [ ! -s "$REAP_CALLS" ]
  [ ! -s "$DEVPOD_UP_CALLS" ]
  [[ "$output" == *"never connected"* ]]
  [[ "$output" != *"reconnecting in"* ]]
}

@test "a live multiplex master also counts as having connected" {
  # OpenSSH skips the hook for a session riding an existing master, so without
  # this signal a reused master would look like it had never connected.
  _dvw_ssh_master_alive() { return 0; }
  printf '255\n0\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(<"$SSH_COUNT")" -eq 2 ]
  [[ "$output" == *"ssh transport lost"* ]]
}

@test "a host that accepts and immediately closes cannot retry forever" {
  # Every attempt connects, so every attempt is retry-worthy. Only a bound that
  # nothing resets stops this; earlier versions spun here indefinitely.
  printf '255|connected\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_TOTAL_MAX=5

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 6 ]  # first attempt + 5 reconnects, then the cap
  [[ "$output" == *"5 reconnects in one session without settling"* ]]
  [[ "$output" == *"reconnect with: dvw myws"* ]]
  [ ! -s "$DEVPOD_UP_CALLS" ]
}

@test "an outage after a real session retries, then stops at the cap" {
  # Connect, drop, then the network stays down: later attempts never connect,
  # but the session is known to have existed, so reconnecting stays sensible
  # until the cap.
  printf '255|connected\n255\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_TOTAL_MAX=4

  run _dvw_ssh_session myws

  [ "$status" -eq 255 ]
  [ "$(<"$SSH_COUNT")" -eq 5 ]
  [[ "$output" == *"4 reconnects in one session without settling"* ]]
}

@test "reconnect attempts carry a connect timeout but the first does not" {
  # A cold container may legitimately be slow to accept the first connection;
  # retries must not be able to stack up unbounded waits.
  printf '255|connected\n0|connected\n' > "$SSH_RESULTS"
  export DVW_SSH_RECONNECT_CONNECT_TIMEOUT=7

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  [ "$(head -1 "$SSH_CALLS" | grep -c ConnectTimeout)" -eq 0 ]
  [ "$(sed -n 2p "$SSH_CALLS" | grep -c 'ConnectTimeout=7')" -eq 1 ]
}

@test "ssh session asks OpenSSH to signal a connection via LocalCommand" {
  printf '0|connected\n' > "$SSH_RESULTS"

  run _dvw_ssh_session myws

  [ "$status" -eq 0 ]
  run grep -F -- "PermitLocalCommand=yes" "$SSH_CALLS"
  [ "$status" -eq 0 ]
  # SSH_CALLS records args with %q, so the space after touch is escaped.
  run grep -E -- "LocalCommand=touch.*dvw-ssh.*connected" "$SSH_CALLS"
  [ "$status" -eq 0 ]
}

@test "ssh session uses workspace alias and tmux work command" {
  printf '0|connected\n' > "$SSH_RESULTS"

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

@test "the connection marker is cleaned up on every exit path" {
  printf '255\n' > "$SSH_RESULTS"
  local before after
  before=$(find /tmp -maxdepth 1 -name 'dvw-ssh.*' 2>/dev/null | wc -l)

  run _dvw_ssh_session myws

  after=$(find /tmp -maxdepth 1 -name 'dvw-ssh.*' 2>/dev/null | wc -l)
  [ "$before" -eq "$after" ]
}

@test "returning from the ssh session leaves no armed RETURN trap in the caller" {
  # Regression: bash keeps a `trap ... RETURN` set inside a function armed after
  # that function returns, so it fired a second time when the *caller* returned
  # — in a scope where $markdir no longer exists. Under `set -u` (which `dvw`
  # sets) that killed the process with "markdir: unbound variable" right after a
  # clean tmux exit, turning status 0 into 1.
  printf '0|connected\n' > "$SSH_RESULTS"

  run bash -euo pipefail -c '
    source "$DVW_ROOT/lib/connect.sh"
    _dvw_reap_stale_masters() { :; }
    _dvw_ssh_master_alive() { return 1; }
    catalog_workspace_touch() { :; }
    outer() { local ws="$1"; _dvw_ssh_session "$ws"; }
    outer myws
    echo CALLER_RETURNED_OK
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *CALLER_RETURNED_OK* ]]
}

@test "marker cleanup removes only a dir we created" {
  local victim="$TMPDIR/precious"
  mkdir -p "$victim/data" && : > "$victim/data/keep"
  local mine="$TMPDIR/dvw-ssh.XYZ"
  mkdir -p "$mine" && : > "$mine/connected"

  _dvw_rm_marker_dir "$mine"
  [ ! -e "$mine" ]

  # Anything we did not name is refused, loudly, without touching it.
  run _dvw_rm_marker_dir "$victim"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to remove unexpected ssh marker dir"* ]]
  [ -f "$victim/data/keep" ]
}

@test "marker cleanup is a no-op on empty, missing, root, and symlink paths" {
  run _dvw_rm_marker_dir ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run _dvw_rm_marker_dir "/"
  [ "$status" -eq 0 ]
  [ -d / ]

  # Absent dir with our own naming: silent success, no error output.
  run _dvw_rm_marker_dir "$TMPDIR/dvw-ssh.gone"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # A symlink is never followed out of TMPDIR, even when named like ours.
  local target="$TMPDIR/target"
  mkdir -p "$target" && : > "$target/keep"
  ln -s "$target" "$TMPDIR/dvw-ssh.link"
  run _dvw_rm_marker_dir "$TMPDIR/dvw-ssh.link"
  [ "$status" -eq 0 ]
  [ -f "$target/keep" ]
}
