#!/usr/bin/env bash
# dvw pin-rebuild: rebuild onto the newest :latest image and assert the
# running container actually got it. `dvw recreate` does the pull and the
# rebuild; this adds the catalog's image_current check, so a rebuild that
# silently lands on a stale image fails loudly.

DVW_PIN_REBUILD_USAGE="usage: dvw pin-rebuild [<workspace-id>...]"

# cmd_pin_rebuild [<workspace-id>...] — no ids = every catalog workspace.
cmd_pin_rebuild() {
  local ids=()
  while (($#)); do
    case "$1" in
      -*) ui_error "unknown flag: $1"; ui_info "$DVW_PIN_REBUILD_USAGE"; return 1 ;;
      *) ids+=("$1") ;;
    esac
    shift
  done

  local ids_raw
  ids_raw=$(_dvw_pin_resolve_ids ${ids[@]+"${ids[@]}"}) || {
    ui_error "couldn't list catalog workspaces, so pin-rebuild cannot know what to rebuild"
    return 1
  }
  mapfile -t ids <<<"$ids_raw"

  local id rc=0
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    _dvw_pin_rebuild_one "$id" || rc=1
  done
  return $rc
}

_dvw_pin_rebuild_one() {
  local id="$1"
  catalog_workspace_get "$id" >/dev/null || { ui_error "unknown workspace: $id"; return 1; }
  ui_banner "dvw pin-rebuild" "$id → $(_dvw_blueprint_pin)"

  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would rebuild $id and verify the image"
    return 0
  fi

  cmd_recreate "$id" || return 1

  # Under :latest the container reports an image ID, so digests are never
  # compared here; the catalog resolves the tag and gives the verdict.
  local insp current
  insp=$(_catalog_req GET "/v1/workspaces/$id/inspect" 2>/dev/null) || insp=""
  current=$(jq -r '.image_current' <<<"$insp" 2>/dev/null) || current=""
  case "$current" in
    true)  ui_status_ok "$id is running the newest image"; return 0 ;;
    false) ui_status_fail "$id rebuilt but is not on the newest image (:latest)"; return 1 ;;
    *)     ui_status_warn "couldn't verify $id's image; check: dvw status"; return 0 ;;
  esac
}
