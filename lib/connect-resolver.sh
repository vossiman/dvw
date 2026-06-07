#!/usr/bin/env bash
# Service-backed overrides for dvw's connect.sh resolver/probe functions.
#
# Source this AFTER lib/connect.sh in the `dvw` entrypoint. It replaces the
# three functions that used to SSH into the provider and reason about docker
# client-side with calls to the authoritative dvw-catalog service:
#
#   _dvw_resolve_canonical_container   -> GET /v1/workspaces/{id}/container
#   _dvw_load_probe                    -> GET /v1/containers/status + /orphans
#   _dvw_provider_has_container        -> GET /v1/workspaces/{id}/container
#
# All the dvw-internal helpers it leans on (_dvw_rewrite_local_uid,
# _dvw_uid_claimed_by_other, catalog_workspace_set_devpod_state) are unchanged.

_CONNECT_RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=catalog-http-lib.sh
. "$_CONNECT_RESOLVER_DIR/catalog-http-lib.sh"

# Resolve the canonical container for a workspace and align the local uid.
# The service computes the bind-mount + tmux tie-break authoritatively, so the
# client just consumes the answer.
_dvw_resolve_canonical_container() {
  local id="$1" path current_uid body cid chosen ambiguous
  path=$(catalog_devpod_workspace_json_path "$id")
  [[ -f "$path" ]] || return 0
  current_uid=$(jq -r '.uid // empty' "$path" 2>/dev/null)

  body=$(_catalog_req GET "/v1/workspaces/$id/container") || {
    ui_status_warn "resolve: catalog service unreachable — proceeding with current local uid"
    return 0
  }

  # Pathological: >=2 sibling containers, none with a live `work` tmux session.
  # The service refuses to guess; mirror the legacy hard stop (status 1).
  ambiguous=$(jq -r '.ambiguous // false' <<<"$body")
  if [[ "$ambiguous" == "true" ]]; then
    ui_status_warn "$id: multiple containers and none has a live tmux \`work\` session — refusing to guess"
    ui_info "  disambiguate manually (e.g. close the stray container) then retry"
    return 1
  fi

  cid=$(jq -r '.container_id // empty' <<<"$body")
  [[ -z "$cid" ]] && return 0   # no live container; nothing to align
  chosen=$(jq -r '.devpod_uid // empty' <<<"$body")
  [[ -z "$chosen" ]] && return 0

  if [[ "$chosen" != "$current_uid" ]]; then
    if _dvw_uid_claimed_by_other "$id" "$chosen"; then
      ui_status_warn "$id: refusing to align to uid=$chosen — already claimed by another workspace"
      return 1
    fi
    ui_status_warn "$id: canonical uid=$chosen (was=${current_uid:-unset}) — aligning local & catalog"
    _dvw_rewrite_local_uid "$id" "$chosen" || return 1
    catalog_workspace_set_devpod_state "$id" >/dev/null 2>&1 || \
      ui_status_warn "could not push uid=$chosen to catalog (will retry next time)"
    ui_status_ok "$id: uid aligned to $chosen"
  fi
  return 0
}

# Bulk per-workspace liveness, served by one local docker pass on the box.
_dvw_load_probe() {
  [[ -n "${DVW_PROBE_LOADED:-}" ]] && return 0
  DVW_PROBE_LOADED=1

  local status_body orphan_body
  status_body=$(_catalog_req GET /v1/containers/status) || {
    DVW_PROBE_ERROR="catalog service unreachable"
    # Mark every catalog id unreachable, matching the original ssh-failure path.
    local id
    while IFS= read -r id; do
      [[ -n "$id" ]] && DVW_PROBE_STATE["$id"]="unreachable"
    done < <(catalog_workspace_ids 2>/dev/null)
    return 0
  }

  local id liveness
  while IFS=$'\t' read -r id liveness; do
    [[ -z "$id" ]] && continue
    DVW_PROBE_STATE["$id"]="$liveness"
  done < <(jq -r '.[] | "\(.id)\t\(.liveness)"' <<<"$status_body")

  # Orphans -> DVW_PROBE_ORPHAN_INFO (host \t name \t state \t mountstatus \t src \t wsdest)
  orphan_body=$(_catalog_req GET /v1/containers/orphans) || return 0
  local uid name state mstatus src wsdest
  while IFS=$'\t' read -r uid name state mstatus src wsdest; do
    [[ -z "$uid" ]] && continue
    DVW_PROBE_ORPHAN_INFO["$uid"]="${DVW_CATALOG_HOST}"$'\t'"${name}"$'\t'"${state}"$'\t'"${mstatus}"$'\t'"${src}"$'\t'"${wsdest}"
    DVW_PROBE_ORPHAN_UIDS+="${uid}"$'\n'
  done < <(jq -r '.[] | "\(.devpod_uid)\t\(.container_name)\t\(.state)\t\(.mount_status)\t\(.mount_source // "")\t\(.workspace_id // "")"' <<<"$orphan_body")
}

# Fresh check: does a container currently exist for this workspace? Used right
# before destructive `devpod up` (the wipe-footgun guard). Always asks the
# service fresh — never the cached probe table.
_dvw_provider_has_container() {
  local id="$1" body cid
  body=$(_catalog_req GET "/v1/workspaces/$id/container") || return 1
  cid=$(jq -r '.container_id // empty' <<<"$body")
  [[ -n "$cid" ]]
}
