#!/usr/bin/env bash

cmd_list() {
  catalog_workspace_ids
}

cmd_rm() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "usage: dvw rm <workspace-id>" >&2
    return 1
  fi
  if ! catalog_workspace_get "$id" >/dev/null 2>&1; then
    echo "workspace not in catalog: $id" >&2
    echo "(if it exists in DevPod but not the catalog, use \`devpod delete $id\` directly)" >&2
    return 1
  fi
  local running="no"
  if devpod list --output json 2>/dev/null \
       | jq -e --arg id "$id" '.[] | select(.id == $id and .status == "Running")' \
         >/dev/null 2>&1; then
    running="yes"
  fi
  if [[ "$running" == "yes" ]]; then
    if ! gum confirm "Workspace $id is running. Delete it?"; then
      echo "aborted"
      return 1
    fi
  fi
  devpod delete "$id" || {
    echo "devpod delete failed; catalog not modified" >&2
    return 1
  }
  catalog_workspace_remove "$id" || {
    echo "[WARN] devpod delete succeeded but catalog write failed — run \`dvw doctor\`" >&2
    return 1
  }
}

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

cmd_doctor() {
  local fail=0
  local cat_path
  cat_path=$(catalog_path)
  local cat_dir
  cat_dir=$(dirname "$cat_path")

  echo "== dvw doctor =="

  # rclone mount
  if mountpoint -q "$cat_dir" 2>/dev/null \
     || mountpoint -q "$(dirname "$cat_dir")" 2>/dev/null; then
    echo "[OK]  rclone mount: $cat_dir is on a FUSE mount"
  elif [[ -d "$cat_dir" ]]; then
    echo "[WARN] rclone mount: $cat_dir exists but is not a mountpoint (regular directory)"
  else
    echo "[FAIL] rclone mount: $cat_dir does not exist"
    echo "       try: systemctl --user status rclone-dropbox"
    fail=1
  fi

  # catalog readable
  local cat_data
  if cat_data=$(catalog_read 2>&1); then
    echo "[OK]  catalog: readable, version=$(echo "$cat_data" | jq -r .version)"
  else
    echo "[FAIL] catalog: $cat_data"
    fail=1
  fi

  # conflicted-copy detection
  if compgen -G "$cat_dir/*conflicted copy*" >/dev/null; then
    echo "[WARN] Dropbox conflicted-copy file(s) present in $cat_dir"
    fail=1
  fi

  # ssh blueprint sync
  ssh_sync_doctor

  # devpod
  if command -v devpod >/dev/null; then
    echo "[OK]  devpod: $(devpod version 2>/dev/null | head -1)"
  else
    echo "[FAIL] devpod: not on PATH (install: https://devpod.sh)"
    fail=1
  fi

  # gum
  if command -v gum >/dev/null; then
    echo "[OK]  gum: $(gum --version 2>/dev/null)"
  else
    echo "[FAIL] gum: not on PATH (install: https://github.com/charmbracelet/gum)"
    fail=1
  fi

  # jq
  if command -v jq >/dev/null; then
    echo "[OK]  jq: $(jq --version)"
  else
    echo "[FAIL] jq: not on PATH"
    fail=1
  fi

  # orphan check: catalog references workspace devpod doesn't know
  if command -v devpod >/dev/null && catalog_read >/dev/null 2>&1; then
    local known_to_devpod
    known_to_devpod=$(devpod list --output json 2>/dev/null | jq -r '.[].id' || true)
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if ! grep -qx "$id" <<<"$known_to_devpod"; then
        echo "[WARN] catalog has \"$id\" but devpod does not (run \`dvw rm $id\` to prune, or re-register with \`devpod up $id\`)"
      fi
    done < <(catalog_workspace_ids)
  fi

  return "$fail"
}
