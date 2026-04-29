#!/usr/bin/env bash

cmd_list() {
  catalog_workspace_ids
}

cmd_rm() { echo "rm: not yet implemented" >&2; return 2; }

cmd_stop() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "usage: dvw stop <workspace-id>" >&2
    return 1
  fi
  devpod stop "$id"
}

cmd_start() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "usage: dvw start <workspace-id>" >&2
    return 1
  fi
  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  devpod up "$id" --ide "$ide"
}

# One line per workspace: <id>  <repo>@<branch>  <ide>  <running?>  last:<last_used_at>  on:<created_on>
cmd_status() {
  local running_ids
  running_ids=$(devpod list --output json 2>/dev/null \
    | jq -r '.[] | select(.status == "Running") | .id' 2>/dev/null \
    || true)
  catalog_read | jq -r --argjson running "$(printf '%s\n' "$running_ids" | jq -R . | jq -s .)" '
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        (.repo + "@" + .branch),
        .ide,
        (if (.id as $id | $running | index($id)) then "running" else "stopped" end),
        ("last:" + .last_used_at),
        ("on:" + .created_on)
      ] | @tsv'
}

cmd_doctor() { echo "doctor: not yet implemented" >&2; return 2; }
