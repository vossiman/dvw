#!/usr/bin/env bash
# dvw watch — the zero-command version of `dvw push` for a bastion (jumpi).
#
# Termius mobile pastes a file by SFTP-uploading it to /tmp on the host the
# SSH session terminates at (jumpi) and typing that path into the terminal.
# The prompt lives in a workspace container, so `dvw push` relays the file to
# the same path there. This watcher does that relay automatically: it polls
# the same roots `dvw push` searches, and every fresh Termius-style upload is
# copied to /tmp in EVERY workspace this machine has a live session with. No
# prompting (a daemon has no UI); a stray file in an unused container's
# ephemeral /tmp is the accepted cost of never guessing wrong.
#
# Lifecycle mirrors clipd (lib/clipd.sh): the connect path calls
# _dvw_push_watch_ensure_quiet, which starts the loop in the background when
# DVW_PUSH_WATCH=1 (set by install-bastion.sh via the dvw config file). The
# loop exits on its own once no live session has existed for a while, so it
# is armed exactly while sessions exist and never outlives them for long.
#
# Spec: docs/superpowers/specs/2026-09-03-dvw-push-watch-design.md

_dvw_push_watch_dir() { echo "$HOME/.dvw"; }
_dvw_push_watch_pidfile() { echo "$(_dvw_push_watch_dir)/push-watch.pid"; }
_dvw_push_watch_log() { echo "$(_dvw_push_watch_dir)/push-watch.log"; }

# Poll interval and how long to keep running with no live session before
# exiting. Seconds; overridable for tests.
: "${DVW_PUSH_WATCH_INTERVAL:=1}"
: "${DVW_PUSH_WATCH_IDLE_EXIT:=120}"
# Minimum age (seconds since last write) before an upload counts as settled.
# Size-stable across two polls alone would deliver an SFTP stream that merely
# stalled for one interval, truncated, and never resend it.
: "${DVW_PUSH_WATCH_SETTLE:=2}"
# Extension allowlist (spec): the watcher delivers without asking, so it only
# touches the kinds of files a phone paste produces. Lowercased, space
# separated. `dvw push <file>` remains the route for anything else.
: "${DVW_PUSH_WATCH_EXTS:=png jpg jpeg gif webp heic pdf txt md}"

_dvw_push_watch_enabled() { [[ "${DVW_PUSH_WATCH:-0}" == "1" ]]; }

# Running pid from the pidfile, empty if absent, dead, or reused. The pidfile
# survives a reboot, so a bare kill -0 could bless an unrelated process that
# inherited the number (and `watch stop` would then kill it): the second line
# of the pidfile records the /proc identity (start time + uid, connect.sh's
# _dvw_proc_identity) and must still match.
_dvw_push_watch_live_pid() {
  local pidfile pid recorded current
  pidfile=$(_dvw_push_watch_pidfile)
  [[ -f "$pidfile" ]] || return 0
  { read -r pid; read -r recorded; } < "$pidfile" 2>/dev/null || true
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  if [[ -n "${recorded:-}" ]] && type _dvw_proc_identity >/dev/null 2>&1; then
    current=$(_dvw_proc_identity "$pid")
    [[ -z "$current" || "$current" == "$recorded" ]] || return 0
  fi
  echo "$pid"
  return 0
}

# Upload in progress? True when the file was written to within the settle
# window or, where fuser exists, some process (sftp-server runs as this user)
# still has it open.
_dvw_push_watch_busy() {
  local f="$1" now mtime
  now=$(date +%s) || return 0
  mtime=$(stat -c %Y -- "$f" 2>/dev/null) || return 0
  (( now - mtime < DVW_PUSH_WATCH_SETTLE )) && return 0
  if command -v fuser >/dev/null 2>&1; then
    fuser -s -- "$f" 2>/dev/null && return 0
  fi
  return 1
}

_dvw_push_watch_logline() {
  mkdir -p "$(_dvw_push_watch_dir)" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$(_dvw_push_watch_log)" 2>/dev/null || true
}

# Extension of $1 (lowercased, no dot) is in the allowlist.
_dvw_push_watch_ext_ok() {
  local ext="${1##*.}"
  ext="${ext,,}"
  [[ " $DVW_PUSH_WATCH_EXTS " == *" $ext "* ]]
}

# Attempts per (file, workspace) pair before giving up: a transient catalog
# blip or scp failure is retried on later polls, a workspace that stays
# stopped is not hammered every second for the whole fresh window.
: "${DVW_PUSH_WATCH_ATTEMPTS:=3}"

# Relay $1 to one workspace. RUNNING gate first (never boot a stopped
# workspace via the auto-starting alias), then the same scp `dvw push` uses.
# rc 0 only on a completed transfer; the caller decides whether to retry.
_dvw_push_watch_deliver_one() {
  local f="$1" ws="$2" base rc=0
  base=$(basename -- "$f")
  if [[ "$(_dvw_ws_container_state "$ws")" != yes ]]; then
    _dvw_push_watch_logline "skip $base -> $ws: not running (or catalog unreachable)"
    return 1
  fi
  if ! _dvw_ensure_local_devpod_state "$ws" >/dev/null 2>&1 \
      || ! _dvw_ensure_ssh_alias "$ws" >/dev/null 2>&1; then
    _dvw_push_watch_logline "skip $base -> $ws: alias setup failed"
    return 1
  fi
  scp -q -o BatchMode=yes -- "$f" "${ws}.devpod:/tmp/" || rc=$?
  if (( rc != 0 )); then
    _dvw_push_watch_logline "fail $base -> $ws: scp rc=$rc"
    return 1
  fi
  _dvw_push_watch_logline "ok   $base -> $ws"
  # Confirmation inside the session, best effort: a tmux server in the
  # container shows the landed path briefly. Absent tmux, nothing to show.
  [[ "$(_dvw_ws_container_state "$ws")" == yes ]] || return 0
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${ws}.devpod" \
    tmux display-message -d 3000 "dvw: /tmp/$base ready" >/dev/null 2>&1 || true
  return 0
}

# One poll. State lives in caller-owned associative arrays:
#   DVW_PW_DONE[path]=1        skipped for good (startup backlog, extension)
#   DVW_PW_SIZE[path]=bytes    size at the previous tick (upload guard)
#   DVW_PW_SENT[path|ws]=1     delivered to that workspace
#   DVW_PW_TRIES[path|ws]=n    failed attempts so far for that pair
# A file is delivered only once its size is unchanged since the last tick and
# it has settled (_dvw_push_watch_busy), so a Termius upload still streaming
# in is never copied half-written. Each live workspace is tried separately and
# a failure is retried on later polls, so one bad target never costs the
# others their copy and a blip never loses a paste. Prints nothing; logs.
_dvw_push_watch_tick() {
  local f bytes ws key
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -n "${DVW_PW_DONE[$f]:-}" ]] && continue
    if ! _dvw_push_watch_ext_ok "$f"; then
      DVW_PW_DONE[$f]=1
      _dvw_push_watch_logline "skip $(basename -- "$f"): extension not allowed"
      continue
    fi
    bytes=$(stat -c %s -- "$f" 2>/dev/null) || continue
    if [[ "${DVW_PW_SIZE[$f]:-}" != "$bytes" ]]; then
      DVW_PW_SIZE[$f]=$bytes
      continue
    fi
    _dvw_push_watch_busy "$f" && continue
    while IFS= read -r ws; do
      [[ -n "$ws" ]] || continue
      key="$f|$ws"
      [[ -n "${DVW_PW_SENT[$key]:-}" ]] && continue
      (( ${DVW_PW_TRIES[$key]:-0} >= DVW_PUSH_WATCH_ATTEMPTS )) && continue
      if _dvw_push_watch_deliver_one "$f" "$ws"; then
        DVW_PW_SENT[$key]=1
      else
        DVW_PW_TRIES[$key]=$(( ${DVW_PW_TRIES[$key]:-0} + 1 ))
      fi
    done < <(_dvw_push_live_sessions)
  done < <(_dvw_push_list_fresh)
  return 0
}

# Foreground loop. Files already present when the watcher was *launched* are
# marked done: they were either pushed by hand or are not wanted, and
# re-sending the last ten minutes on every (re)start would be a surprise.
# The cutoff is the launch time handed over by ensure (DVW_PUSH_WATCH_SINCE),
# not the time this scan runs: the child re-runs dvw's preflights first, and
# a paste that lands in that gap must still be delivered.
_dvw_push_watch_run() {
  local -A DVW_PW_DONE=() DVW_PW_SIZE=() DVW_PW_SENT=() DVW_PW_TRIES=()
  local f idle=0 sessions since mtime
  since="${DVW_PUSH_WATCH_SINCE:-$(date +%s)}"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mtime=$(stat -c %Y -- "$f" 2>/dev/null) || continue
    (( mtime < since )) && DVW_PW_DONE[$f]=1
  done < <(_dvw_push_list_fresh)
  _dvw_push_watch_logline "start pid=$$ interval=${DVW_PUSH_WATCH_INTERVAL}s idle-exit=${DVW_PUSH_WATCH_IDLE_EXIT}s"
  while :; do
    sessions=$(_dvw_push_live_sessions)
    if [[ -z "$sessions" ]]; then
      idle=$(( idle + DVW_PUSH_WATCH_INTERVAL ))
      if (( idle >= DVW_PUSH_WATCH_IDLE_EXIT )); then
        _dvw_push_watch_logline "exit: no live session for ${idle}s"
        return 0
      fi
    else
      idle=0
      _dvw_push_watch_tick
    fi
    sleep "$DVW_PUSH_WATCH_INTERVAL"
  done
}

# Start the background loop unless one is already running. The loop is a
# child of a fresh `dvw watch run` process so it survives the connect that
# spawned it and picks up code changes from a dvw update on its next start.
_dvw_push_watch_ensure() {
  local dir
  dir=$(_dvw_push_watch_dir)
  mkdir -p "$dir"
  chmod 700 "$dir"
  # Check-and-launch under a lock: two attaches arriving together must not
  # both pass the pid check and start two loops (double delivery, and only
  # the last pidfile writer could ever be stopped).
  (
    exec 9>"$dir/push-watch.lock"
    flock -w 10 9 || { ui_error "watch: could not take the start lock"; exit 1; }
    _dvw_push_watch_launch
  )
}

_dvw_push_watch_launch() {
  local pid since
  pid=$(_dvw_push_watch_live_pid)
  [[ -n "$pid" ]] && return 0
  since=$(date +%s)
  ( DVW_PUSH_WATCH_SINCE="$since" setsid "$DVW_ROOT/dvw" watch run 9>&- \
      >> "$(_dvw_push_watch_log)" 2>&1 \
      & { echo $!; type _dvw_proc_identity >/dev/null 2>&1 && _dvw_proc_identity $!; } \
      > "$(_dvw_push_watch_pidfile)" ) </dev/null
  sleep 0.2
  pid=$(_dvw_push_watch_live_pid)
  if [[ -z "$pid" ]]; then
    rm -f "$(_dvw_push_watch_pidfile)"
    ui_error "watch: failed to start (see $(_dvw_push_watch_log))"
    return 1
  fi
  return 0
}

# Connect-path hook: only when enabled, best effort, never blocks a session.
_dvw_push_watch_ensure_quiet() {
  _dvw_push_watch_enabled || return 0
  _dvw_push_watch_ensure >/dev/null 2>&1 || true
  return 0
}

cmd_watch() {
  local sub="${1:-status}"
  case "$sub" in
    run)
      _dvw_push_watch_run ;;
    ensure|start)
      _dvw_push_watch_ensure && ui_status_ok "watch: running (pid $(_dvw_push_watch_live_pid))" ;;
    status)
      local pid
      pid=$(_dvw_push_watch_live_pid)
      if [[ -n "$pid" ]]; then
        ui_status_ok "watch: running (pid $pid, log $(_dvw_push_watch_log))"
      else
        ui_info "watch: not running"
      fi
      if _dvw_push_watch_enabled; then
        ui_info "watch: auto-start on connect is on (DVW_PUSH_WATCH=1)"
      else
        ui_info "watch: auto-start on connect is off — set DVW_PUSH_WATCH=1 in $DVW_CONFIG (install-bastion.sh does this)"
      fi ;;
    stop)
      local pid
      pid=$(_dvw_push_watch_live_pid)
      if [[ -z "$pid" ]]; then
        ui_info "watch: not running"
      else
        kill "$pid" 2>/dev/null || true
        ui_info "watch: stopped (pid $pid)"
      fi
      rm -f "$(_dvw_push_watch_pidfile)" ;;
    *)
      ui_error "watch: unknown subcommand '$sub' (status|start|stop|run)"
      return 1 ;;
  esac
}
