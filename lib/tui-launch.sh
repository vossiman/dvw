#!/usr/bin/env bash
# Launcher for the Textual TUI (bare `dvw`). Decides availability, guarantees
# a LOCAL unix socket to the catalog service, and hands off to `uv run`.
# Fallback to the gum menu (ui_top_menu) stays in dvw's dispatch — this file
# only ever says "can run / cannot run" and "run it".
#
# Env:
#   DVW_NO_TUI=1     force the gum menu (escape hatch)
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
