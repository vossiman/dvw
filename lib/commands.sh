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

  local known_locally=0
  if command -v devpod >/dev/null 2>&1 \
     && devpod list --output json 2>/dev/null \
        | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
    known_locally=1
  fi

  if (( known_locally )); then
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
  else
    ui_action "removing" "$id (catalog-only — not registered with this machine's devpod)"
    if ! gum confirm "Remove catalog entry only? Remote provider state may be left orphaned."; then
      ui_info "aborted"
      return 1
    fi
  fi

  catalog_workspace_remove "$id" || {
    ui_status_warn "catalog write failed — run \`dvw doctor\`"
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
  _dvw_ensure_local_devpod_state "$id" || return 1
  _dvw_reconcile_uid "$id" || return 1
  _dvw_reap_stale_masters "$id"
  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  ui_action "starting" "$id (ide=$ide)"
  devpod up "$id" --ide "$ide" || return 1
  catalog_workspace_set_devpod_state "$id" 2>/dev/null || true
}

# Force-rebuild the container so a freshly-pushed devcontainer.json (or any
# image/postCreate change) takes effect. Same IDE resolution as cmd_start.
cmd_recreate() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw recreate <workspace-id>"
    return 1
  fi
  _dvw_ensure_local_devpod_state "$id" || return 1
  _dvw_reconcile_uid "$id" || return 1
  _dvw_reap_stale_masters "$id"
  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  ui_action "recreating" "$id (ide=$ide)"
  devpod up "$id" --recreate --ide "$ide" || return 1
  catalog_workspace_set_devpod_state "$id" 2>/dev/null || true
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

  # Surface stale-bind-mount workspaces below the table. These look "running"
  # in the row above but Cursor will fatal on connect; the SSH+tmux path keeps
  # working because bash tolerates a dead cwd. Only probes workspaces already
  # marked Running, so the SSH cost is bounded.
  _dvw_load_stale_ids
  if [[ -n "$DVW_STALE_IDS" ]]; then
    echo
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      ui_status_warn "$id has a stale workspace bind mount — \`dvw recreate $id\` to fix"
    done <<<"$DVW_STALE_IDS"
  fi
}

# Drop the canonical devcontainer.json from devpod/blueprint/ into the in-
# container checkout of a running DevPod workspace. The file lands in the
# workspace's repo working tree (/workspaces/<repo-basename>/.devcontainer/),
# from where the user can commit + push it. The live container is NOT
# reconfigured — the blueprint takes effect on the next workspace rebuild
# (or a fresh `dvw new`) once the change is in the remote branch.
cmd_blueprint() {
  ui_banner "install blueprint" "push devcontainer.json into a running workspace's checkout"

  local src="$DVW_ROOT/blueprint/devcontainer.json"
  if [[ ! -f "$src" ]]; then
    ui_error "blueprint not found at $src"
    return 1
  fi

  local id
  id=$(ui_pick_workspace "blueprint into> ") || { ui_info "aborted"; return 1; }

  # DevPod (vossisrv setup) clones the repo into /workspaces/<workspace-id>
  # — the in-container folder name is the workspace id, not the repo basename.
  local container_dir="/workspaces/$id"
  local container_dst="$container_dir/.devcontainer/devcontainer.json"

  # Wake the workspace if it's not reachable. Same probe pattern as cmd_connect.
  _dvw_reap_stale_masters "$id"
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${id}.devpod" true 2>/dev/null; then
    _dvw_ensure_local_devpod_state "$id" || return 1
    _dvw_reconcile_uid "$id" || return 1
    ui_info "workspace not reachable — starting (devpod up --ide none)..."
    _dvw_safe_devpod_up "$id" --ide none >/dev/null || { ui_error "failed to start $id"; return 1; }
    catalog_workspace_set_devpod_state "$id" 2>/dev/null || true
  fi

  if ! ssh "${id}.devpod" "test -d $container_dir" 2>/dev/null; then
    ui_error "repo working tree not found at $container_dir inside $id"
    ui_info "  (devpod may have cloned to a non-standard path — open a shell with \`dvw $id\` to check)"
    return 1
  fi

  # Skip the write if the blueprint is already in place and identical.
  local remote_md5 local_md5
  remote_md5=$(ssh "${id}.devpod" "md5sum $container_dst 2>/dev/null | awk '{print \$1}'") || true
  local_md5=$(md5sum "$src" | awk '{print $1}')
  if [[ -n "$remote_md5" && "$remote_md5" == "$local_md5" ]]; then
    ui_status_ok "$container_dst already matches the blueprint — nothing to do"
    return 0
  fi
  if [[ -n "$remote_md5" ]]; then
    ui_status_warn "$container_dst already exists and differs from the blueprint"
    gum confirm "Overwrite with the blueprint?" || { ui_info "aborted"; return 1; }
  fi

  if ssh "${id}.devpod" "mkdir -p $container_dir/.devcontainer && cat > $container_dst" < "$src"; then
    ui_action "installed" "${id}:$container_dst"
  else
    ui_error "failed to write $container_dst inside $id"
    return 1
  fi

  echo
  ui_info "next step (apply the blueprint to this workspace):"
  ui_info "  dvw recreate $id"
  ui_info ""
  ui_info "the file is in the working tree but uncommitted. To make the blueprint"
  ui_info "stick for any future \`dvw new\` from this repo, also commit + push:"
  ui_info "  dvw $id   # attach"
  ui_info "  cd $container_dir && git add .devcontainer && git commit -m 'add devpod blueprint' && git push"
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
  local devpod_providers=""
  local -a needed_providers=() missing_providers=()
  if command -v devpod >/dev/null; then
    ui_status_ok "devpod: $(devpod version 2>/dev/null | head -1)"
    devpod_providers=$(devpod provider list --output json 2>/dev/null | jq -r 'keys[]?' || true)

    # devpod resolves providers by name, not by type — a workspace.json that
    # says provider=vossisrv fails on a machine that only has a generic `ssh`
    # provider, even though both would dial the same host. Diff the catalog's
    # required names against what's installed and surface each gap.
    if catalog_read >/dev/null 2>&1; then
      mapfile -t needed_providers < <(catalog_read | jq -r '.workspaces[].provider // empty' | grep -v '^$' | sort -u)
      local p
      for p in "${needed_providers[@]}"; do
        grep -qx "$p" <<<"$devpod_providers" || missing_providers+=("$p")
      done
    fi

    if [[ -n "$devpod_providers" ]]; then
      ui_status_ok "devpod providers: $(printf '%s\n' "$devpod_providers" | paste -sd, -)"
    elif (( ${#needed_providers[@]} == 0 )); then
      ui_status_fail "devpod providers: none configured (run \`devpod provider add ssh --name vossisrv --option HOST=<user@host>\` then \`devpod provider use vossisrv\`)"
      fail=$((fail+1))
    fi
    # If devpod_providers is empty AND needed_providers is non-empty, the loop
    # below emits one fail line per missing provider — more actionable than a
    # generic "none configured".

    local p
    for p in "${missing_providers[@]}"; do
      ui_status_fail "provider \"$p\" referenced by catalog but not installed locally (run \`devpod provider add ssh --name $p --option HOST=$p\`)"
      fail=$((fail+1))
    done
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

  # Per-workspace registration status. Catalog is the cross-machine source of
  # truth (Dropbox-synced); local devpod state is per-machine and may not yet
  # exist for catalog entries created elsewhere — that's fine, the synthesizer
  # in connect.sh will materialize it on first connect. This block is purely
  # informational and never tries to "fix" anything.
  if command -v devpod >/dev/null && catalog_read >/dev/null 2>&1; then
    _dvw_load_stale_ids   # populates DVW_STALE_IDS via parallel SSH probes
    local known_to_devpod
    known_to_devpod=$(devpod list --output json 2>/dev/null | jq -r '.[].id' || true)
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      local has_snapshot=0
      if catalog_workspace_get_devpod_state "$id" >/dev/null 2>&1; then
        has_snapshot=1
      fi
      if grep -qx "$id" <<<"$known_to_devpod"; then
        ui_status_ok "workspace \"$id\": registered locally"
      elif (( has_snapshot )); then
        ui_status_ok "workspace \"$id\": pending sync (will register on first \`dvw $id\`)"
      else
        ui_status_warn "workspace \"$id\": legacy entry — no devpod_state snapshot in catalog (\`dvw rm $id\` then \`dvw new\` to migrate)"
        warn=$((warn+1))
      fi
      # Independent of registration: a running container with a stale bind
      # mount looks healthy to devpod but breaks Cursor. Surface as a fail
      # so the user runs `dvw recreate` before clicking connect.
      if [[ -n "$DVW_STALE_IDS" ]] && grep -qx "$id" <<<"$DVW_STALE_IDS"; then
        ui_status_fail "workspace \"$id\": stale bind mount (cwd is deleted) — \`dvw recreate $id\`"
        fail=$((fail+1))
      fi
    done < <(catalog_workspace_ids)
  fi

  # Offer to add any catalog-referenced provider that's missing locally. Fires
  # on the gap (set difference), not on the empty-list case — so a user who
  # has a generic `ssh` provider installed but whose catalog asks for a named
  # `vossisrv` one still gets the prompt.
  if (( ${#missing_providers[@]} > 0 )) && [[ -t 0 ]] && command -v gum >/dev/null; then
    local p
    for p in "${missing_providers[@]}"; do
      if ! ssh -G "$p" >/dev/null 2>&1; then
        echo
        ui_status_warn "can't auto-add provider \"$p\": no matching \`Host $p\` in ~/.ssh/config"
        continue
      fi
      echo
      if gum confirm "Add devpod SSH provider \"$p\" using SSH host alias \"$p\"?"; then
        ui_action "adding provider" "$p (devpod provider add ssh --name $p --option HOST=$p)"
        if devpod provider add ssh --name "$p" --option "HOST=$p"; then
          ui_status_ok "added provider \"$p\""
          fail=$((fail-1))
        else
          ui_status_warn "failed to add provider \"$p\" (run \`devpod provider add ssh --name $p --option HOST=$p\` manually)"
        fi
      fi
    done
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
