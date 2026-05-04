#!/usr/bin/env bash
# Connect to a workspace and attach the `work` tmux session.

cmd_connect() {
  local ws="$1"
  if [[ -z "$ws" ]]; then
    echo "cmd_connect: workspace ID required" >&2
    return 1
  fi

  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
    local ide="none" ws_json
    if ws_json=$(catalog_workspace_get "$ws" 2>/dev/null); then
      ide=$(echo "$ws_json" | jq -r '.ide')
      [[ "$ide" == "ssh" ]] && ide="none"
    else
      echo "(workspace not in catalog — defaulting to --ide none)"
    fi
    echo "starting workspace $ws (ide=$ide) ..."
    devpod up "$ws" --ide "$ide"
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
