#!/usr/bin/env bash
# Connect to a workspace via SSH (terminal + tmux session) or Cursor (GUI).

cmd_connect() {
  local ws="$1"
  shift || true
  if [[ -z "$ws" ]]; then
    ui_error "cmd_connect: workspace ID required"
    return 1
  fi

  # Optional flags to skip the chooser for non-interactive use:
  #   dvw <id> --ssh     — go straight to ssh+tmux
  #   dvw <id> --cursor  — go straight to Cursor (devpod up --ide cursor)
  local forced_mode=""
  case "${1:-}" in
    --ssh)    forced_mode="ssh" ;;
    --cursor) forced_mode="cursor" ;;
    "")       : ;;
    *) ui_error "unknown flag: $1 (expected --ssh or --cursor)"; return 1 ;;
  esac

  # Catalog's ide field is the default highlighted option; user can override.
  local default_ide="ssh" ws_json
  if ws_json=$(catalog_workspace_get "$ws" 2>/dev/null); then
    default_ide=$(echo "$ws_json" | jq -r '.ide // "ssh"')
  fi

  local mode="$forced_mode"
  if [[ -z "$mode" ]]; then
    mode=$(_connect_choose_mode "$ws" "$default_ide")
    [[ -z "$mode" ]] && return 1
  fi

  case "$mode" in
    ssh)    _connect_ssh "$ws" ;;
    cursor) _connect_cursor "$ws" ;;
    *)      ui_error "unknown connect mode: $mode"; return 1 ;;
  esac
}

# Prompt SSH vs Cursor with the catalog's saved IDE pre-selected. Echoes
# "ssh" or "cursor" on stdout; empty on cancel.
_connect_choose_mode() {
  local ws="$1" default_ide="$2"
  if ! command -v gum >/dev/null; then
    echo "ssh"
    return 0
  fi
  local ssh_label="SSH (terminal + tmux)"
  local cursor_label="Cursor (GUI)"
  local selected="$ssh_label"
  [[ "$default_ide" == "cursor" ]] && selected="$cursor_label"

  local choice
  choice=$(gum choose \
    --header="connect to $ws via" \
    --selected="$selected" \
    --cursor "❯ " \
    --cursor.foreground "$DVW_ACCENT" \
    --selected.foreground "$DVW_ACCENT" \
    "$ssh_label" "$cursor_label")

  case "$choice" in
    "$ssh_label")    echo "ssh" ;;
    "$cursor_label") echo "cursor" ;;
    *)               echo "" ;;
  esac
}

# SSH path: probe-up if needed, then ssh -t into a tmux `work` session.
_connect_ssh() {
  local ws="$1"
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
    ui_action "starting" "$ws (ide=none)"
    devpod up "$ws" --ide none
  fi
  catalog_workspace_touch "$ws" 2>/dev/null || true
  # Single ssh call: probe tmux inside the same login shell that will host
  # the session, so we don't pay for two TCP+auth+`bash -l` round-trips.
  exec ssh -t "${ws}.devpod" '
    infocmp -1 "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color
    if command -v tmux >/dev/null 2>&1; then
      exec bash -lc "tmux new -A -s work"
    fi
    echo "tmux not found in this workspace. Falling back to plain bash (no resume)." >&2
    echo "To bootstrap the full toolchain inside the workspace:" >&2
    echo "  git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh" >&2
    exec bash -l
  '
}

# Cursor path: hand off to devpod up --ide cursor. Brings the workspace up
# if it's not running, then opens Cursor via the cursor-shim wrapper.
_connect_cursor() {
  local ws="$1"
  catalog_workspace_touch "$ws" 2>/dev/null || true
  ui_action "opening" "$ws in Cursor"
  exec devpod up "$ws" --ide cursor
}
