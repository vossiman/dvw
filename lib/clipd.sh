#!/usr/bin/env bash
# dvw clipd — lifecycle for the client-side clipboard server (clipd/dvw-clipd.py).
#
# The server feeds the clipboard bridge: containers reach it through the
# managed blueprint's `RemoteForward /tmp/dvw-clip.sock %d/.dvw/clip.sock`.
# `ensure` is called from the connect path (quiet, never fatal) so any client
# that opens a workspace session has the bridge live without thinking about it.
# Spec: docs/superpowers/specs/2026-08-27-clipboard-bridge-design.md

_dvw_clipd_dir() { echo "$HOME/.dvw"; }
_dvw_clipd_pidfile() { echo "$(_dvw_clipd_dir)/clipd.pid"; }
_dvw_clipd_socket() { echo "$(_dvw_clipd_dir)/clip.sock"; }
_dvw_clipd_log() { echo "$(_dvw_clipd_dir)/clipd.log"; }

# Running pid from the pidfile, empty if absent or dead.
_dvw_clipd_live_pid() {
  local pidfile pid
  pidfile=$(_dvw_clipd_pidfile)
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
  return 0
}

_dvw_clipd_ensure() {
  local pid
  pid=$(_dvw_clipd_live_pid)
  [[ -n "$pid" ]] && return 0
  command -v python3 >/dev/null || {
    ui_error "clipd: python3 not found — clipboard bridge unavailable"
    return 1
  }
  local dir
  dir=$(_dvw_clipd_dir)
  mkdir -p "$dir"
  chmod 700 "$dir"
  ( setsid python3 "$DVW_ROOT/clipd/dvw-clipd.py" --socket "$(_dvw_clipd_socket)" \
      >> "$(_dvw_clipd_log)" 2>&1 & echo $! > "$(_dvw_clipd_pidfile)" ) </dev/null
  # Confirm it came up; a server that dies instantly must not leave a pidfile.
  sleep 0.2
  pid=$(_dvw_clipd_live_pid)
  if [[ -z "$pid" ]]; then
    rm -f "$(_dvw_clipd_pidfile)"
    ui_error "clipd: server failed to start (see $(_dvw_clipd_log))"
    return 1
  fi
  return 0
}

# Connect-path hook: best effort, silent on failure, never blocks a session.
_dvw_clipd_ensure_quiet() {
  _dvw_clipd_ensure >/dev/null 2>&1 || true
  return 0
}

cmd_clipd() {
  local sub="${1:-status}"
  case "$sub" in
    ensure)
      _dvw_clipd_ensure ;;
    status)
      local pid
      pid=$(_dvw_clipd_live_pid)
      if [[ -n "$pid" ]]; then
        ui_status_ok "clipd: running (pid $pid, socket $(_dvw_clipd_socket))"
      else
        ui_info "clipd: not running"
      fi ;;
    stop)
      local pid
      pid=$(_dvw_clipd_live_pid)
      if [[ -z "$pid" ]]; then
        ui_info "clipd: not running"
      else
        kill "$pid" 2>/dev/null || true
        ui_info "clipd: stopped (pid $pid)"
      fi
      rm -f "$(_dvw_clipd_pidfile)" "$(_dvw_clipd_socket)" ;;
    *)
      ui_error "clipd: unknown subcommand '$sub' (ensure|status|stop)"
      return 1 ;;
  esac
}
