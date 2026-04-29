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

  exec ssh -t "${ws}.devpod" \
    'infocmp -1 "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color; bash -lc "tmux new -A -s work"'
}
