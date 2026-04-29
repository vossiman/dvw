#!/usr/bin/env bash
# Connect to a workspace and attach the `work` tmux session.

cmd_connect() {
  local ws="$1"
  if [[ -z "$ws" ]]; then
    echo "cmd_connect: workspace ID required" >&2
    return 1
  fi

  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
    local ide="none"
    if catalog_workspace_get "$ws" >/dev/null 2>&1; then
      ide=$(catalog_workspace_get "$ws" | jq -r '.ide')
      [[ "$ide" == "ssh" ]] && ide="none"
    fi
    echo "starting workspace $ws (ide=$ide) ..."
    devpod up "$ws" --ide "$ide"
  fi

  catalog_workspace_touch "$ws" 2>/dev/null || true

  exec ssh -t "${ws}.devpod" \
    'infocmp -1 "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color; bash -lc "tmux new -A -s work"'
}
