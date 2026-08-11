#!/usr/bin/env bash
# Launcher for the Textual TUI (bare `dvw`). Decides availability, guarantees
# a LOCAL unix socket to the catalog service, and hands off to `uv run`.
# When unavailable (or the launch fails), dvw's dispatch reports an error and
# exits — bare `dvw` is TUI-or-error since 2026-08-10, no menu fallback. This
# file only ever says "can run / cannot run" and "run it".
#
# Env:
#   DVW_NO_TUI=1     disable the TUI (bare `dvw` then errors out)
#   DVW_TUI_FORCE=1  skip the tty/uv checks (tests only)

# Can the TUI run here? Pure check, no side effects.
_dvw_tui_available() {
  [[ "${DVW_NO_TUI:-}" == "1" ]] && return 1
  [[ -d "$DVW_ROOT/tui" ]] || return 1
  if [[ "${DVW_TUI_FORCE:-}" != "1" ]]; then
    [[ -t 0 && -t 1 ]] || return 1
  fi
  command -v uv >/dev/null 2>&1 || return 1
  return 0
}

# Why can't the TUI run here? Prints the FIRST failing prerequisite, in the
# same order _dvw_tui_available checks them. Only meaningful when
# _dvw_tui_available just returned 1.
_dvw_tui_unavailable_reason() {
  if [[ "${DVW_NO_TUI:-}" == "1" ]]; then
    printf 'DVW_NO_TUI=1 is set'
  elif [[ ! -d "$DVW_ROOT/tui" ]]; then
    printf 'tui/ is missing from this install'
  elif [[ "${DVW_TUI_FORCE:-}" != "1" ]] && [[ ! -t 0 || ! -t 1 ]]; then
    printf 'not running in a terminal'
  elif ! command -v uv >/dev/null 2>&1; then
    printf 'uv is not on PATH (run dvw doctor)'
  else
    printf 'unknown reason'
  fi
}

# Print the path of a local unix socket that reaches the catalog service.
# On the box: the service socket itself. Remote: an ssh -L UDS forward,
# reused across launches when still healthy.
_dvw_tui_ensure_socket() {
  local sock="${DVW_CATALOG_SOCK:-/run/dvw-catalog/catalog.sock}"
  if [[ -S "$sock" ]]; then
    printf '%s' "$sock"
    return 0
  fi
  local dir="${XDG_RUNTIME_DIR:-/tmp}"
  local fwd="$dir/dvw-catalog-fwd-$(id -u).sock"
  # Probe sends no token, so with auth enabled this returns 401 — that's fine;
  # we only need transport liveness here, not a successful auth round-trip.
  if [[ -S "$fwd" ]] && curl -sS --unix-socket "$fwd" --max-time 2 \
       http://localhost/v1/health >/dev/null 2>&1; then
    printf '%s' "$fwd"
    return 0
  fi
  rm -f "$fwd"
  ssh -f -N -o BatchMode=yes -o ConnectTimeout=5 \
      -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
      -L "$fwd:$sock" \
      "${DVW_CATALOG_HOST:-vossisrv}" 2>/dev/null || return 1
  [[ -S "$fwd" ]] || return 1
  printf '%s' "$fwd"
}

# Run the TUI. Returns nonzero (instead of exec) so dvw can fall back.
dvw_tui_launch() {
  local sock
  if ! sock=$(_dvw_tui_ensure_socket); then
    ui_error "catalog socket unreachable — TUI needs the catalog service"
    return 1
  fi
  DVW_TUI_SOCKET="$sock" \
  DVW_BIN="$DVW_ROOT/dvw" \
    uv run --project "$DVW_ROOT/tui" dvw-tui
}
