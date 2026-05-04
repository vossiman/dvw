#!/usr/bin/env bash

cmd_list() {
  catalog_workspace_ids
}

cmd_rm() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw rm <workspace-id>"
    return 1
  fi
  if ! catalog_workspace_get "$id" >/dev/null 2>&1; then
    ui_error "workspace not in catalog: $id"
    ui_info "(if it exists in DevPod but not the catalog, use \`devpod delete $id\` directly)"
    return 1
  fi
  _dvw_load_running_ids
  if printf '%s\n' "$DVW_RUNNING_IDS" | grep -qFx "$id"; then
    if ! gum confirm "Workspace $id is running. Delete it?"; then
      ui_info "aborted"
      return 1
    fi
  fi
  ui_action "removing" "$id"
  devpod delete "$id" || {
    ui_error "devpod delete failed; catalog not modified"
    return 1
  }
  catalog_workspace_remove "$id" || {
    ui_status_warn "devpod delete succeeded but catalog write failed — run \`dvw doctor\`"
    return 1
  }
}

cmd_stop() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw stop <workspace-id>"
    return 1
  fi
  ui_action "stopping" "$id"
  devpod stop "$id"
}

cmd_start() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw start <workspace-id>"
    return 1
  fi
  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  ui_action "starting" "$id (ide=$ide)"
  devpod up "$id" --ide "$ide"
}

# Banner + column-aligned colored rows. Columns: id, repo@branch, ide,
# ●running/○stopped, last:<ts>, on:<host>. Same colorization as the picker.
cmd_status() {
  _dvw_load_running_ids
  ui_banner "dvw status"
  local raw
  raw=$(catalog_read 2>/dev/null | jq -r --arg running "$DVW_RUNNING_IDS" '
    ($running | split("\n") | map(select(. != ""))) as $r |
    def shortrepo:
      sub("^git@github\\.com:"; "")
      | sub("^https://github\\.com/"; "")
      | sub("\\.git$"; "");
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        ((.repo | shortrepo) + "@" + .branch),
        .ide,
        (if (.id as $id | $r | index($id)) then "● running" else "○ stopped" end),
        ("last:" + .last_used_at),
        ("on:" + .created_on)
      ] | @tsv
  ')
  if [[ -z "$raw" ]]; then
    ui_info "no workspaces in catalog"
    return 0
  fi
  printf '%s\n' "$raw" \
    | column -t -s $'\t' -o '  ·  ' \
    | _ui_colorize_workspace_row \
    | sed 's/^/  /'
}

# Drop the canonical devcontainer.json from devpod/blueprint/ into a target
# repo's .devcontainer/. Useful for repos that don't yet have one — after
# running this, commit and push the new file, then `dvw new` against the
# branch to bring up a properly-configured workspace.
cmd_blueprint() {
  local target="${1:-}"

  ui_banner "install blueprint" "drop devcontainer.json into a target repo so dvw new can build a proper workspace"

  if [[ -z "$target" ]]; then
    local default="$PWD"
    [[ "$PWD" == "$HOME" && -d "$HOME/local_dev" ]] && default="$HOME/local_dev"
    target=$(gum input \
      --value "$default" \
      --header "target repo directory (absolute path)" \
      --header.foreground "$DVW_SUBTLE")
  fi
  [[ -z "$target" ]] && { ui_info "aborted: no target"; return 1; }
  target="${target/#\~/$HOME}"
  if ! target=$(cd "$target" 2>/dev/null && pwd); then
    ui_error "target directory does not exist: ${1:-$target}"
    return 1
  fi
  if ! git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
    ui_status_warn "$target is not a git repository (blueprint will still be copied)"
  fi

  local src="$DVW_ROOT/blueprint/devcontainer.json"
  if [[ ! -f "$src" ]]; then
    ui_error "blueprint not found at $src"
    return 1
  fi

  local dst_dir="$target/.devcontainer"
  local dst="$dst_dir/devcontainer.json"

  if [[ -f "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      ui_status_ok "$dst already matches the blueprint — nothing to do"
      return 0
    fi
    ui_status_warn "$dst already exists and differs from the blueprint"
    ui_info "  (run \`diff -u $dst $src\` to inspect)"
    gum confirm "Overwrite with the blueprint?" || { ui_info "aborted"; return 1; }
  fi

  mkdir -p "$dst_dir"
  cp -- "$src" "$dst"
  ui_action "installed" "$dst"

  echo
  ui_info "next steps:"
  ui_info "  cd $target"
  ui_info "  git add .devcontainer/devcontainer.json"
  ui_info "  git commit -m 'add devpod blueprint'"
  ui_info "  git push"
  ui_info "  dvw new    # then create a workspace from the new branch"
}

cmd_doctor() {
  local fail=0 warn=0
  local cat_path cat_dir
  cat_path=$(catalog_path)
  cat_dir=$(dirname "$cat_path")

  ui_banner "dvw doctor" "health check across all dvw surfaces"

  # rclone mount
  if mountpoint -q "$cat_dir" 2>/dev/null \
     || mountpoint -q "$(dirname "$cat_dir")" 2>/dev/null; then
    ui_status_ok "rclone mount: $cat_dir is on a FUSE mount"
  elif [[ -d "$cat_dir" ]]; then
    ui_status_warn "rclone mount: $cat_dir exists but is not a mountpoint (regular directory)"
    warn=$((warn+1))
  else
    ui_status_fail "rclone mount: $cat_dir does not exist"
    ui_info "          try: systemctl --user status rclone-dropbox"
    fail=$((fail+1))
  fi

  # catalog readable
  local cat_data
  if cat_data=$(catalog_read 2>&1); then
    ui_status_ok "catalog: readable, version=$(echo "$cat_data" | jq -r .version)"
  else
    ui_status_fail "catalog: $cat_data"
    fail=$((fail+1))
  fi

  # conflicted-copy detection
  if compgen -G "$cat_dir/*conflicted copy*" >/dev/null; then
    ui_status_warn "Dropbox conflicted-copy file(s) present in $cat_dir"
    warn=$((warn+1))
  fi

  # ssh blueprint sync (delegates to ssh-sync.sh, which uses ui_status_*)
  ssh_sync_doctor

  # devpod
  if command -v devpod >/dev/null; then
    ui_status_ok "devpod: $(devpod version 2>/dev/null | head -1)"
  else
    ui_status_fail "devpod: not on PATH (install: https://devpod.sh)"
    fail=$((fail+1))
  fi

  # gum
  if command -v gum >/dev/null; then
    ui_status_ok "gum: $(gum --version 2>/dev/null)"
  else
    ui_status_fail "gum: not on PATH (install: https://github.com/charmbracelet/gum)"
    fail=$((fail+1))
  fi

  # jq
  if command -v jq >/dev/null; then
    ui_status_ok "jq: $(jq --version)"
  else
    ui_status_fail "jq: not on PATH"
    fail=$((fail+1))
  fi

  # orphan check: catalog references workspace devpod doesn't know
  if command -v devpod >/dev/null && catalog_read >/dev/null 2>&1; then
    local known_to_devpod
    known_to_devpod=$(devpod list --output json 2>/dev/null | jq -r '.[].id' || true)
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if ! grep -qx "$id" <<<"$known_to_devpod"; then
        ui_status_warn "catalog has \"$id\" but devpod does not (run \`dvw rm $id\` to prune, or re-register with \`devpod up $id\`)"
        warn=$((warn+1))
      fi
    done < <(catalog_workspace_ids)
  fi

  echo
  if (( fail > 0 )); then
    printf '%s✗%s %s%d failure(s)%s, %s%d warning(s)%s\n' \
      "$(_ansi "$DVW_RED" bold)" "$(ui_reset)" \
      "$(_ansi "$DVW_RED")" "$fail" "$(ui_reset)" \
      "$(_ansi "$DVW_YELLOW")" "$warn" "$(ui_reset)"
  elif (( warn > 0 )); then
    printf '%s⚠%s %s%d warning(s)%s\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" \
      "$(_ansi "$DVW_YELLOW")" "$warn" "$(ui_reset)"
  else
    printf '%s✓%s %sall checks passed%s\n' \
      "$(_ansi "$DVW_GREEN" bold)" "$(ui_reset)" \
      "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)"
  fi
  return "$fail"
}
