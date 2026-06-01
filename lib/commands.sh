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
    _dvw_run_or_print devpod delete "$id" || {
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

  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would remove $id from catalog"
    return 0
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
  _dvw_run_or_print devpod stop "$id"
}

# Probe-aware start. The provider probe (set in _dvw_load_probe) tells us
# precisely what state the workspace is in, so each case maps to the safe
# action:
#
#   alive       — already running. No-op; print the connect hint.
#   stale       — running but bind mount is dead. Refuse; point to recreate.
#                 `devpod up` here is the wipe footgun.
#   stopped     — container exists, not running. Safe to start via the
#                 wrapper (which still asks the provider as belt-and-braces).
#   absent      — no container at all. Same: safe `devpod up` via wrapper.
#   unreachable — couldn't query the provider from this machine. Refuse —
#                 starting blind risks the wipe path. Surface the ssh error
#                 captured in DVW_PROBE_ERROR.
#   unknown     — legacy entry without uid/HOST snapshot in catalog. Fall
#                 through to the old behavior so legacy workspaces still work.
cmd_start() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw start <workspace-id>"
    return 1
  fi
  _dvw_ensure_local_devpod_state "$id" || return 1
  _dvw_ensure_ssh_alias "$id" || return 1
  _dvw_resolve_canonical_container "$id" || return 1
  _dvw_reap_stale_masters "$id"

  _dvw_load_probe
  local state="${DVW_PROBE_STATE[$id]:-unknown}"
  case "$state" in
    alive)
      ui_status_ok "$id is already running"
      ui_info "  connect: dvw $id"
      return 0
      ;;
    stale)
      ui_error "$id has a stale workspace bind mount — refusing to start"
      ui_info "  \`devpod up\` against a stale-running container is the wipe footgun."
      ui_info "  recover: dvw recreate $id"
      return 1
      ;;
    unreachable)
      ui_error "$id is unreachable from this machine — refusing to start"
      [[ -n "$DVW_PROBE_ERROR" ]] && ui_info "  ssh: $DVW_PROBE_ERROR"
      ui_info "  fix the network/SSH path to the provider, then retry."
      return 1
      ;;
    stopped|absent|unknown|*) : ;;
  esac

  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  ui_action "starting" "$id (ide=$ide, state=$state)"
  _dvw_safe_devpod_up "$id" --ide "$ide" || return 1
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
  _dvw_resolve_canonical_container "$id" || return 1
  _dvw_reap_stale_masters "$id"
  local ide="none"
  if catalog_workspace_get "$id" >/dev/null 2>&1; then
    ide=$(catalog_workspace_get "$id" | jq -r '.ide')
    [[ "$ide" == "ssh" ]] && ide="none"
  fi
  ui_action "recreating" "$id (ide=$ide)"
  _dvw_run_or_print devpod up "$id" --recreate --ide "$ide" || return 1
  catalog_workspace_set_devpod_state "$id" 2>/dev/null || true
}

# Banner + column-aligned colored rows. Columns: id, repo@branch, ide,
# <state-glyph>, last:<ts>, on:<host>. Same 5-state colorization as the
# picker: ● running / ⚠ stale / ○ stopped / ✗ absent / ? unreachable.
#
# Backed by the provider-first probe (one ssh to vossisrv, see
# _dvw_load_probe in connect.sh). The footer surfaces ssh errors for the
# unreachable case so "I can't ask the provider" is never silently rendered
# as "container is down".
cmd_status() {
  _dvw_load_running_ids
  ui_banner "dvw status"
  local raw
  raw=$(catalog_read 2>/dev/null | jq -r \
        --arg alive       "$DVW_ALIVE_IDS" \
        --arg stale       "$DVW_STALE_IDS" \
        --arg stopped     "$DVW_STOPPED_IDS" \
        --arg absent      "$DVW_ABSENT_IDS" \
        --arg unreachable "$DVW_UNREACHABLE_IDS" '
    def lines: split("\n") | map(select(. != ""));
    ($alive | lines)       as $a |
    ($stale | lines)       as $s |
    ($stopped | lines)     as $o |
    ($absent | lines)      as $b |
    ($unreachable | lines) as $u |
    def shortrepo:
      sub("^git@github\\.com:"; "")
      | sub("^https://github\\.com/"; "")
      | sub("\\.git$"; "");
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        ((.repo | shortrepo) + "@" + .branch),
        .ide,
        (.id as $id
         | if   ($s | index($id)) then "⚠ stale"
           elif ($a | index($id)) then "● running"
           elif ($o | index($id)) then "○ stopped"
           elif ($b | index($id)) then "✗ absent"
           elif ($u | index($id)) then "? unreachable"
           else                        "? unknown" end),
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

  # Footer: surface anything the row colorization can't fully explain.
  if [[ -n "$DVW_UNREACHABLE_IDS" ]]; then
    echo
    ui_status_warn "provider unreachable from this machine"
    [[ -n "$DVW_PROBE_ERROR" ]] && ui_info "  ssh: $DVW_PROBE_ERROR"
    ui_info "  rows shown as \`? unreachable\` reflect the inability to ask the"
    ui_info "  provider — NOT that the containers are down."
  fi
  if [[ -n "$DVW_STALE_IDS" ]]; then
    echo
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      ui_status_warn "$id has a stale workspace bind mount — \`dvw recreate $id\` to fix"
    done <<<"$DVW_STALE_IDS"
  fi
  if [[ -n "$DVW_ABSENT_IDS" ]]; then
    echo
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      ui_status_warn "$id is in the catalog but no container exists on its provider"
      ui_info "  start it: dvw start $id   |   remove the stale catalog entry: dvw rm $id"
    done <<<"$DVW_ABSENT_IDS"
  fi
}

# Drop the canonical devcontainer.json from blueprint/ into the in-
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

  # Wake the workspace if it's not reachable. Same cold-branch policy as
  # cmd_connect: if the alias probe fails but a container exists on the
  # provider, treat as alive (just skip the up call) — never `devpod up`
  # against a confirmed-existing container.
  _dvw_reap_stale_masters "$id"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${id}.devpod" true 2>/dev/null; then
    _dvw_ensure_local_devpod_state "$id" || return 1
    _dvw_resolve_canonical_container "$id" || return 1
    if _dvw_provider_has_container "$id"; then
      ui_status_ok "$id: container is running (alias probe was slow); proceeding"
    else
      ui_info "workspace not reachable — starting (devpod up --ide none)..."
      _dvw_safe_devpod_up "$id" --ide none >/dev/null || { ui_error "failed to start $id"; return 1; }
      catalog_workspace_set_devpod_state "$id" 2>/dev/null || true
    fi
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

  # Provider probe — surfaced first because every cross-machine "container
  # not running" symptom traces back through this. Forces a probe load and
  # reports whether ssh to the provider host succeeded plus the resulting
  # per-state buckets. Read-only on the provider; cannot mutate containers.
  _dvw_load_probe
  _dvw_load_running_ids
  if [[ -n "$DVW_UNREACHABLE_IDS" ]] && [[ -z "$DVW_ALIVE_IDS$DVW_STALE_IDS$DVW_STOPPED_IDS$DVW_ABSENT_IDS" ]]; then
    ui_status_fail "provider probe: unreachable from this machine"
    [[ -n "$DVW_PROBE_ERROR" ]] && ui_info "          ssh: $DVW_PROBE_ERROR"
    fail=$((fail+1))
  elif [[ -n "$DVW_UNREACHABLE_IDS" ]]; then
    ui_status_warn "provider probe: partial (some hosts unreachable)"
    [[ -n "$DVW_PROBE_ERROR" ]] && ui_info "         ssh: $DVW_PROBE_ERROR"
    warn=$((warn+1))
  else
    local n_alive n_stale n_stopped n_absent
    n_alive=$(grep -c . <<<"$DVW_ALIVE_IDS" || true)
    n_stale=$(grep -c . <<<"$DVW_STALE_IDS" || true)
    n_stopped=$(grep -c . <<<"$DVW_STOPPED_IDS" || true)
    n_absent=$(grep -c . <<<"$DVW_ABSENT_IDS" || true)
    ui_status_ok "provider probe: alive=$n_alive stale=$n_stale stopped=$n_stopped absent=$n_absent"
  fi

  # Orphan containers: labelled devpod containers whose uid isn't claimed
  # by any agent workspace dir. Tier 1 surface: per-orphan name/state/mount
  # status so the user can decide at a glance whether to inspect further.
  # An orphan may STILL contain uncommitted work or unpushed commits inside
  # its bind-mounted /workspaces dir — never recommend automatic cleanup.
  # The deeper git-state audit (Tier 2) is reachable from the menu when any
  # orphan exists.
  if [[ -n "${DVW_PROBE_ORPHAN_UIDS:-}" ]]; then
    local n_orphans orphan_uid
    n_orphans=$(grep -c . <<<"$DVW_PROBE_ORPHAN_UIDS" || true)
    ui_status_warn "$n_orphans orphan container(s) on provider — may contain data, verify before removing"
    warn=$((warn+1))
    while IFS= read -r orphan_uid; do
      [[ -z "$orphan_uid" ]] && continue
      local info="${DVW_PROBE_ORPHAN_INFO[$orphan_uid]:-}"
      if [[ -n "$info" ]]; then
        local o_host o_name o_state o_mstatus o_msrc o_wsdest
        IFS=$'\t' read -r o_host o_name o_state o_mstatus o_msrc o_wsdest <<<"$info"
        case "$o_mstatus" in
          alive)
            ui_info "          $orphan_uid · $o_name · $o_state · /workspaces/$o_wsdest mount alive (may contain data)"
            ;;
          deleted)
            ui_info "          $orphan_uid · $o_name · $o_state · /workspaces/$o_wsdest mount stale (deleted inode — workspaces data unrecoverable)"
            ;;
          nomount)
            ui_info "          $orphan_uid · $o_name · $o_state · no /workspaces mount"
            ;;
          *)
            ui_info "          $orphan_uid · $o_name · $o_state · mount status unknown"
            ;;
        esac
      else
        ui_info "          $orphan_uid (no detail available)"
      fi
    done <<<"$DVW_PROBE_ORPHAN_UIDS"
    ui_info "         (run \`dvw\` and pick \"Audit orphan containers\" for git status / unpushed / stashes inside each)"
  fi

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

  # per-workspace ssh alias coverage: every catalog workspace should resolve a
  # local `<id>.devpod` ProxyCommand. Misses mean this machine can't open them
  # until `dvw <id>` (which now self-registers) or `dvw start <id>` runs.
  local _alias_missing=()
  local _wid
  while IFS= read -r _wid; do
    [[ -z "$_wid" ]] && continue
    _dvw_alias_defined "$_wid" || _alias_missing+=("$_wid")
  done < <(catalog_read 2>/dev/null | jq -r '.workspaces[]?.id' 2>/dev/null)
  if (( ${#_alias_missing[@]} == 0 )); then
    ui_status_ok "ssh aliases: all catalog workspaces resolve locally"
  else
    ui_status_warn "ssh aliases: missing for ${_alias_missing[*]} — run \`dvw <id>\` to register (auto on connect)"
    warn=$((warn+1))
  fi

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
    if [[ -n "${DVW_PROBE_ORPHAN_UIDS:-}" ]]; then
      ui_info "  audit orphans for unsaved work via \`dvw\` menu → \"Audit orphan containers\""
    fi
  elif (( warn > 0 )); then
    printf '%s⚠%s %s%d warning(s)%s\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" \
      "$(_ansi "$DVW_YELLOW")" "$warn" "$(ui_reset)"
    if [[ -n "${DVW_PROBE_ORPHAN_UIDS:-}" ]]; then
      ui_info "  audit orphans for unsaved work via \`dvw\` menu → \"Audit orphan containers\""
    fi
  else
    printf '%s✓%s %sall checks passed%s\n' \
      "$(_ansi "$DVW_GREEN" bold)" "$(ui_reset)" \
      "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)"
  fi
  return "$fail"
}

# Tier-2 orphan audit: for each orphan container, surface git state inside
# its /workspaces bind mount so the user can decide whether to copy
# anything out before removing. Triggered from the top menu (not from
# `dvw doctor` directly) because it does docker exec per orphan and can
# be slow if there are many.
#
# Container-safety: read-only. The remote script never invokes docker
# rm/stop/restart, never writes to any bind mount, never touches the
# catalog. It only runs `git status / log / stash list` (and `docker
# exec` of those, for running orphans).
cmd_orphans_audit() {
  ui_banner "audit orphan containers" "git status / unpushed / stashes inside each"

  _dvw_load_probe
  if [[ -z "${DVW_PROBE_ORPHAN_UIDS:-}" ]]; then
    ui_info "no orphan containers detected"
    return 0
  fi

  # Group orphans by host so we can do one ssh per host.
  declare -A host_orphans=()
  local uid info host
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    info="${DVW_PROBE_ORPHAN_INFO[$uid]:-}"
    [[ -z "$info" ]] && continue
    host=$(awk -F'\t' '{print $1}' <<<"$info")
    [[ -z "$host" ]] && continue
    host_orphans["$host"]+="$uid"$'\n'
  done <<<"$DVW_PROBE_ORPHAN_UIDS"

  local h
  for h in "${!host_orphans[@]}"; do
    _dvw_audit_orphans_on_host "$h" "${host_orphans[$h]}"
  done
}

# Run the audit for one host. Bundles all this host's orphans into a single
# ssh round-trip, passes uid/name/state/mountstatus/mountsrc/wsdest as
# positional args (groups of 6). The remote loops, emits a structured
# block per orphan. Output is parsed and rendered client-side.
_dvw_audit_orphans_on_host() {
  local host="$1" uids="$2"
  local args=() uid info
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    info="${DVW_PROBE_ORPHAN_INFO[$uid]:-}"
    [[ -z "$info" ]] && continue
    local _h o_name o_state o_mstatus o_msrc o_wsdest
    IFS=$'\t' read -r _h o_name o_state o_mstatus o_msrc o_wsdest <<<"$info"
    args+=("$uid" "$o_name" "$o_state" "$o_mstatus" "$o_msrc" "$o_wsdest")
  done <<<"$uids"

  if (( ${#args[@]} == 0 )); then
    return 0
  fi

  ui_action "auditing" "$host (${#args[@]} args / $(( ${#args[@]} / 6 )) orphans)"

  local quoted=""
  local arg
  for arg in "${args[@]}"; do
    quoted+=" $(printf '%q' "$arg")"
  done

  local out rc=0
  out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "bash -s --$quoted" 2>&1 <<'REMOTE' || rc=$?
set +e
# Args arrive in groups of 6: uid name state mstatus msrc wsdest
while [ "$#" -ge 6 ]; do
  uid="$1"; name="$2"; state="$3"; mstatus="$4"; msrc="$5"; wsdest="$6"
  shift 6
  printf '===ORPHAN_BEGIN===\t%s\t%s\t%s\t%s\t%s\t%s\n' "$uid" "$name" "$state" "$mstatus" "$msrc" "$wsdest"

  case "$mstatus" in
    nomount)
      echo "verdict=no-workspaces-mount"
      echo "===ORPHAN_END==="
      continue
      ;;
    deleted)
      echo "verdict=mount-deleted-unrecoverable"
      echo "===ORPHAN_END==="
      continue
      ;;
  esac

  # mount alive — inspect git state.
  if [ "$state" = "running" ]; then
    out=$(timeout 10 docker exec "$name" sh -c "
      cd /workspaces/$wsdest 2>/dev/null || { echo 'cd_failed'; exit 0; }
      if [ ! -d .git ]; then echo 'no_git'; exit 0; fi
      printf 'branch=%s\n' \"\$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo unknown)\"
      printf 'modified=%s\n' \"\$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')\"
      upstream=\$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)
      if [ -n \"\$upstream\" ]; then
        printf 'upstream=%s\n' \"\$upstream\"
        printf 'unpushed=%s\n' \"\$(git rev-list --count '@{u}..' 2>/dev/null | tr -d ' ')\"
      else
        printf 'upstream=none\n'
        printf 'unpushed=unknown\n'
      fi
      printf 'stashes=%s\n' \"\$(git stash list 2>/dev/null | wc -l | tr -d ' ')\"
    " 2>&1)
    erc=$?
    if [ "$erc" -ne 0 ]; then
      echo "verdict=inspect-failed"
      echo "error=$(echo "$out" | head -1)"
    else
      echo "$out"
    fi
  else
    # stopped / exited — read the host-side bind mount source directly.
    if [ ! -d "$msrc" ]; then
      echo "verdict=mountsrc-missing"
      echo "===ORPHAN_END==="
      continue
    fi
    if [ ! -d "$msrc/.git" ]; then
      echo "no_git"
    else
      cd "$msrc" 2>/dev/null
      printf 'branch=%s\n' "$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo unknown)"
      printf 'modified=%s\n' "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      upstream=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)
      if [ -n "$upstream" ]; then
        printf 'upstream=%s\n' "$upstream"
        printf 'unpushed=%s\n' "$(git rev-list --count '@{u}..' 2>/dev/null | tr -d ' ')"
      else
        printf 'upstream=none\n'
        printf 'unpushed=unknown\n'
      fi
      printf 'stashes=%s\n' "$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
    fi
  fi
  echo "===ORPHAN_END==="
done
REMOTE
)

  if (( rc != 0 )); then
    ui_status_fail "audit ssh to $host failed (rc=$rc)"
    ui_info "$out"
    return 1
  fi

  _dvw_render_audit_output "$host" "$out"
}

# Render the structured audit output. Walks ORPHAN_BEGIN/END blocks, parses
# key=value lines, emits a colored summary per orphan with a verdict.
_dvw_render_audit_output() {
  local host="$1" out="$2"
  echo
  local in_block=0
  local b_uid b_name b_state b_mstatus b_msrc b_wsdest
  local verdict branch modified unpushed stashes upstream err other_flag
  local line
  while IFS= read -r line; do
    if [[ "$line" == "===ORPHAN_BEGIN==="* ]]; then
      in_block=1
      local _marker
      IFS=$'\t' read -r _marker b_uid b_name b_state b_mstatus b_msrc b_wsdest <<<"$line"
      verdict=""; branch=""; modified=""; unpushed=""; stashes=""; upstream=""; err=""; other_flag=""
      continue
    fi
    if [[ "$line" == "===ORPHAN_END===" ]]; then
      in_block=0
      _dvw_print_one_orphan_audit
      continue
    fi
    if (( in_block )); then
      case "$line" in
        verdict=*)  verdict="${line#verdict=}" ;;
        branch=*)   branch="${line#branch=}" ;;
        modified=*) modified="${line#modified=}" ;;
        unpushed=*) unpushed="${line#unpushed=}" ;;
        upstream=*) upstream="${line#upstream=}" ;;
        stashes=*)  stashes="${line#stashes=}" ;;
        error=*)    err="${line#error=}" ;;
        no_git)     other_flag="no_git" ;;
        cd_failed)  other_flag="cd_failed" ;;
      esac
    fi
  done <<<"$out"

  echo
  ui_info "to remove an orphan after verifying it has no data you need:"
  ui_info "  ssh $host 'docker rm -f <container-name>'"
  ui_info "(dvw does not perform this for you on purpose — destructive ops stay manual)"
}

# Print one orphan's audit summary using the variables set in the calling
# scope (b_*, verdict, branch, modified, unpushed, stashes, upstream, err).
# Verdict emoji: ✓ clean, ⚠ has-work, ✗ unrecoverable, ? unknown.
_dvw_print_one_orphan_audit() {
  local header="$b_uid · $b_name · $b_state · /workspaces/$b_wsdest"
  printf '  %s%s%s\n' "$(_ansi "$DVW_ACCENT" bold)" "$header" "$(ui_reset)"
  case "$verdict" in
    no-workspaces-mount)
      printf '    %s✓%s no /workspaces mount — nothing to lose\n' "$(_ansi "$DVW_GREEN" bold)" "$(ui_reset)"
      return
      ;;
    mount-deleted-unrecoverable)
      printf '    %s✗%s bind mount source on host is gone (deleted inode) — no recoverable data\n' "$(_ansi "$DVW_RED" bold)" "$(ui_reset)"
      printf '    %ssource was: %s%s\n' "$(_ansi "$DVW_SUBTLE")" "$b_msrc" "$(ui_reset)"
      return
      ;;
    mountsrc-missing)
      printf '    %s✗%s bind mount source path missing on host: %s\n' "$(_ansi "$DVW_RED" bold)" "$(ui_reset)" "$b_msrc"
      return
      ;;
    inspect-failed)
      printf '    %s?%s could not inspect: %s\n' "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" "${err:-unknown}"
      return
      ;;
  esac

  if [[ "$other_flag" == "no_git" ]]; then
    printf '    %s?%s /workspaces/%s has no .git — no git state to lose; check for unsaved files manually\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" "$b_wsdest"
    return
  fi
  if [[ "$other_flag" == "cd_failed" ]]; then
    printf '    %s?%s cannot cd into /workspaces/%s inside container\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" "$b_wsdest"
    return
  fi

  # Numeric fields default to 0 / empty.
  local m="${modified:-0}" u="${unpushed:-0}" s="${stashes:-0}"
  local has_work=0
  [[ "$m" != "0" ]] && has_work=1
  [[ "$u" != "0" && "$u" != "unknown" ]] && has_work=1
  [[ "$s" != "0" ]] && has_work=1

  printf '    branch:      %s\n' "${branch:-?}"
  printf '    modified:    %s file(s)\n' "$m"
  if [[ "$upstream" == "none" ]]; then
    printf '    upstream:    none (cannot tell if commits are pushed)\n'
  else
    printf '    upstream:    %s\n' "${upstream:-?}"
    printf '    unpushed:    %s commit(s)\n' "$u"
  fi
  printf '    stashes:     %s\n' "$s"

  if (( has_work )); then
    printf '    %s⚠%s has uncommitted / unpushed / stashed work — copy out before removing\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)"
  elif [[ "$upstream" == "none" ]]; then
    printf '    %s?%s clean working tree but no upstream — unable to confirm commits are pushed\n' \
      "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)"
  else
    printf '    %s✓%s clean — no uncommitted/unpushed/stashed git state detected\n' \
      "$(_ansi "$DVW_GREEN" bold)" "$(ui_reset)"
  fi
}
