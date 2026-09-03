#!/usr/bin/env bats
# Bastion push watcher (lib/push-watch.sh): tick semantics (upload-in-progress
# guard, startup skip, extension allowlist, fan-out to every live session,
# RUNNING gate), lifecycle (ensure/status/stop), and the connect-path hook
# being gated on DVW_PUSH_WATCH. scp/ssh stubbed on PATH; registry, catalog
# and alias setup stubbed at the function boundary.

bats_require_minimum_version 1.5.0

UUID_A="570d7e98-a20a-4e6a-ab30-c4b3400ae490"
UUID_B="58974eff-d6aa-4fab-8c75-7a5a925d36de"

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  SCP_ARGS="$TMPDIR/scp-args"; : > "$SCP_ARGS"
  SSH_ARGS="$TMPDIR/ssh-args"; : > "$SSH_ARGS"
  export SCP_ARGS SSH_ARGS
  cat > "$STUB_BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SCP_ARGS"
exit "${SCP_STUB_RC:-0}"
EOF
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_ARGS"
exit 0
EOF
  chmod +x "$STUB_BIN/scp" "$STUB_BIN/ssh"
  export DVW_PUSH_WATCH_INTERVAL=1
  export DVW_PUSH_WATCH_SETTLE=0
  export DVW_ROOT
}

teardown() {
  if [[ -f "$HOME/.dvw/push-watch.pid" ]]; then
    kill "$(head -n1 "$HOME/.dvw/push-watch.pid")" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}

_load() {
  ERRS="$TMPDIR/errs"; : > "$ERRS"
  ui_error() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_info() { printf '%s\n' "$1"; }
  ui_status_ok() { printf 'OK: %s\n' "$1"; }
  _dvw_log_action() { :; }
  source "$DVW_ROOT/lib/connect.sh"
  source "$DVW_ROOT/lib/push.sh"
  source "$DVW_ROOT/lib/push-watch.sh"
  export LIVE="$TMPDIR/live"; printf 'ws1\n' > "$LIVE"
  _dvw_push_live_sessions() { cat "$LIVE"; }
  _dvw_ws_container_state() { echo "${STATE_OVERRIDE:-yes}"; }
  _dvw_ensure_ssh_alias() { return 0; }
  _dvw_ensure_local_devpod_state() { return 0; }
  declare -gA DVW_PW_DONE=() DVW_PW_SIZE=() DVW_PW_SENT=() DVW_PW_TRIES=()
}

_scp_count() { grep -c '\.devpod:/tmp/$' "$SCP_ARGS" || true; }

@test "a fresh upload is delivered on the second tick (size stable), once" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 1 ]
  grep -qx 'ws1.devpod:/tmp/' "$SCP_ARGS"
  grep -qx "$TMPDIR/$UUID_A.png" "$SCP_ARGS"
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 1 ]
}

@test "an upload still growing is not delivered until its size settles" {
  _load
  printf 'aaaa' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick
  printf 'bbbbbbbb' >> "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 1 ]
}

@test "a file written within the settle window is held back" {
  _load
  export DVW_PUSH_WATCH_SETTLE=60
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick; _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
  touch -d '-120 seconds' "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 1 ]
}

@test "live_pid: a reused pid with a different /proc identity is not ours" {
  _load
  mkdir -p "$HOME/.dvw"
  printf '%s\nbogus-identity\n' "$$" > "$HOME/.dvw/push-watch.pid"
  [ -z "$(_dvw_push_watch_live_pid)" ]
  printf '%s\n%s\n' "$$" "$(_dvw_proc_identity $$)" > "$HOME/.dvw/push-watch.pid"
  [ "$(_dvw_push_watch_live_pid)" = "$$" ]
  rm -f "$HOME/.dvw/push-watch.pid"
}

@test "delivery fans out to every live session workspace" {
  _load
  printf 'ws1\nws2\n' > "$LIVE"
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  grep -qx 'ws1.devpod:/tmp/' "$SCP_ARGS"
  grep -qx 'ws2.devpod:/tmp/' "$SCP_ARGS"
}

@test "a workspace that is not running is skipped, never booted via the alias" {
  _load
  export STATE_OVERRIDE=no
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
  grep -q 'not running' "$HOME/.dvw/push-watch.log"
}

@test "extension outside the allowlist is ignored" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.zip"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
  grep -q 'extension not allowed' "$HOME/.dvw/push-watch.log"
}

@test "non-Termius names in /tmp are never touched" {
  _load
  printf 'data' > "$TMPDIR/shot.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  [ "$(_scp_count)" -eq 0 ]
}

@test "a transient failure is retried on the next poll, then delivered once" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.png"
  SCP_STUB_RC=1 _dvw_push_watch_tick
  SCP_STUB_RC=1 _dvw_push_watch_tick
  [ "$(grep -c 'fail.*ws1' "$HOME/.dvw/push-watch.log")" -eq 1 ]
  _dvw_push_watch_tick
  _dvw_push_watch_tick
  [ "$(grep -c 'ok   .*ws1' "$HOME/.dvw/push-watch.log")" -eq 1 ]
  [ "$(_scp_count)" -eq 2 ]
}

@test "a target that keeps failing is given up after DVW_PUSH_WATCH_ATTEMPTS" {
  _load
  export DVW_PUSH_WATCH_ATTEMPTS=2 SCP_STUB_RC=1
  printf 'data' > "$TMPDIR/$UUID_A.png"
  for _ in 1 2 3 4 5; do _dvw_push_watch_tick; done
  [ "$(_scp_count)" -eq 2 ]
}

@test "a workspace attached later still receives an already-delivered file" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  printf 'ws1\nws2\n' > "$LIVE"
  _dvw_push_watch_tick
  [ "$(grep -c 'ws1.devpod' "$SCP_ARGS")" -eq 1 ]
  [ "$(grep -c 'ws2.devpod' "$SCP_ARGS")" -eq 1 ]
}

@test "one failing target does not stop delivery to the others" {
  _load
  printf 'ws1\nws2\n' > "$LIVE"
  cat > "$STUB_BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SCP_ARGS"
[[ "$*" == *ws1.devpod* ]] && exit 1
exit 0
EOF
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  grep -qx 'ws2.devpod:/tmp/' "$SCP_ARGS"
  grep -q 'fail.*ws1' "$HOME/.dvw/push-watch.log"
}

@test "delivery confirms in the container's tmux, best effort" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.png"
  _dvw_push_watch_tick; _dvw_push_watch_tick
  grep -q "ws1.devpod tmux display-message .*dvw: /tmp/$UUID_A.png ready" "$SSH_ARGS"
}

@test "run: files older than the launch cutoff are skipped, newer ones delivered, exits when idle" {
  _load
  export DVW_PUSH_WATCH_IDLE_EXIT=2
  printf 'old' > "$TMPDIR/$UUID_A.png"
  touch -d '-30 seconds' "$TMPDIR/$UUID_A.png"
  # Launch cutoff is a few seconds ago; B lands before the scan (a paste in
  # the preflight gap) but after the cutoff, so it must still be delivered.
  export DVW_PUSH_WATCH_SINCE=$(( $(date +%s) - 5 ))
  printf 'new' > "$TMPDIR/$UUID_B.png"
  ( sleep 4; : > "$LIVE" ) &
  run -0 timeout 15 bash -c '
    source "$DVW_ROOT/lib/connect.sh"; source "$DVW_ROOT/lib/push.sh"; source "$DVW_ROOT/lib/push-watch.sh"
    _dvw_log_action() { :; }
    _dvw_push_live_sessions() { cat "$LIVE"; }
    _dvw_ws_container_state() { echo yes; }
    _dvw_ensure_ssh_alias() { return 0; }
    _dvw_ensure_local_devpod_state() { return 0; }
    _dvw_push_watch_run'
  wait
  run grep -c "$UUID_A" "$SCP_ARGS"; [ "$output" = "0" ]
  run grep -c "$UUID_B.png$" "$SCP_ARGS"; [ "$output" = "1" ]
  grep -q 'exit: no live session' "$HOME/.dvw/push-watch.log"
}

@test "ensure: starts a background loop with a pidfile; second ensure is a no-op" {
  _load
  cat > "$STUB_BIN/dvw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HOME/dvw-args"
exec sleep 300
EOF
  chmod +x "$STUB_BIN/dvw"
  DVW_ROOT="$STUB_BIN"
  run -0 _dvw_push_watch_ensure
  pid=$(head -n1 "$HOME/.dvw/push-watch.pid")
  kill -0 "$pid"
  [ "$(cat "$HOME/dvw-args" | tr '\n' ' ')" = "watch run " ]
  [[ -f "$HOME/.dvw/push-watch.lock" ]]
  run -0 _dvw_push_watch_ensure
  [ "$(head -n1 "$HOME/.dvw/push-watch.pid")" = "$pid" ]
  run -0 cmd_watch status
  [[ "$output" == *"running (pid $pid"* ]]
  run -0 cmd_watch stop
  [[ ! -f "$HOME/.dvw/push-watch.pid" ]]
  run -0 cmd_watch status
  [[ "$output" == *"not running"* ]]
}

@test "ensure: two concurrent starts launch exactly one loop" {
  _load
  cat > "$STUB_BIN/dvw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$HOME/dvw-pids"
sleep 300 & wait
STUB
  chmod +x "$STUB_BIN/dvw"
  DVW_ROOT="$STUB_BIN"
  _dvw_push_watch_ensure & _dvw_push_watch_ensure & wait
  sleep 0.3
  [ "$(wc -l < "$HOME/dvw-pids")" -eq 1 ]
  [ "$(head -n1 "$HOME/.dvw/push-watch.pid")" = "$(cat "$HOME/dvw-pids")" ]
  cmd_watch stop >/dev/null
}

@test "ensure_quiet is a no-op unless DVW_PUSH_WATCH=1" {
  _load
  ENSURE_CALLS=0
  _dvw_push_watch_ensure() { ENSURE_CALLS=$((ENSURE_CALLS+1)); }
  unset DVW_PUSH_WATCH
  _dvw_push_watch_ensure_quiet
  [ "$ENSURE_CALLS" -eq 0 ]
  DVW_PUSH_WATCH=0 _dvw_push_watch_ensure_quiet
  [ "$ENSURE_CALLS" -eq 0 ]
  DVW_PUSH_WATCH=1 _dvw_push_watch_ensure_quiet
  [ "$ENSURE_CALLS" -eq 1 ]
}

@test "config file DVW_PUSH_WATCH=1 is honoured by dvw_load_config" {
  source "$DVW_ROOT/lib/config.sh"
  mkdir -p "$HOME/.config/dvw"
  printf 'DVW_PUSH_WATCH=1\n' > "$HOME/.config/dvw/config"
  unset DVW_PUSH_WATCH
  DVW_CONFIG="$HOME/.config/dvw/config" dvw_load_config
  [ "${DVW_PUSH_WATCH:-}" = "1" ]
}
