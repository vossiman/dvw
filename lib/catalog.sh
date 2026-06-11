#!/usr/bin/env bash
# Service-backed implementation of dvw's catalog layer.
#
# Every workspace/repo/defaults operation goes to the dvw-catalog service over
# HTTP (reached via the transport in catalog-http-lib.sh). The rest of dvw
# (connect.sh, commands.sh) sources this and is unchanged.
#
# Functions that are inherently client-local (devpod context + the path to
# devpod's per-machine workspace.json) keep their original local behavior.

_CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=catalog-http-lib.sh
. "$_CATALOG_LIB_DIR/catalog-http-lib.sh"

# Descriptive "path" for doctor/log messages.
catalog_path() {
  echo "service://${DVW_CATALOG_HOST}${DVW_CATALOG_SOCK}"
}

# Replaces the "create the JSON file if missing" startup gate. Here it means
# "is the service reachable?". Print actionable guidance if not.
catalog_init_if_missing() {
  if _catalog_reachable; then
    return 0
  fi
  echo "catalog service unreachable: ${DVW_CATALOG_HOST}:${DVW_CATALOG_SOCK}" >&2
  echo "try: ssh ${DVW_CATALOG_HOST} systemctl status dvw-catalog" >&2
  return 1
}

# Whole catalog, legacy schema (for `dvw doctor` and ad-hoc jq).
catalog_read() {
  local body
  body=$(_catalog_req GET /v1/catalog) || {
    echo "catalog service unreachable or returned an error" >&2
    return 1
  }
  printf '%s\n' "$body"
}

# ISO-8601 UTC timestamp helper (still local; cheap).
catalog_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

catalog_workspace_ids() {
  local body
  body=$(_catalog_req GET /v1/workspaces) || return 1
  jq -r '.[].id' <<<"$body"   # server already returns MRU order
}

catalog_workspace_get() {
  local id="$1" body rc
  # NB: capture the rc of the substitution (it carries _catalog_req's return).
  # DVW_CAT_STATUS is set in a subshell here and would NOT propagate.
  body=$(_catalog_req GET "/v1/workspaces/$id"); rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '%s\n' "$body"; return 0
  fi
  echo "workspace not found in catalog: $id" >&2
  return 1
}

# Args: id repo branch ide provider host
catalog_workspace_add() {
  local id="$1" repo="$2" branch="$3" ide="$4" provider="$5" host="$6"
  local payload
  payload=$(jq -n --arg id "$id" --arg repo "$repo" --arg branch "$branch" \
    --arg ide "$ide" --arg provider "$provider" --arg host "$host" \
    '{id:$id, repo:$repo, branch:$branch, ide:$ide, provider:$provider, created_on:$host}')
  # `|| true`: _catalog_req returns non-zero on >=400; without this, dvw's
  # `set -e` would abort before the status dispatch below ever runs.
  _catalog_req POST /v1/workspaces "$payload" >/dev/null || true
  case "$DVW_CAT_STATUS" in
    2*) return 0 ;;
    409) echo "workspace ID already exists: $id" >&2; return 1 ;;
    *)   echo "catalog: failed to add workspace $id (status ${DVW_CAT_STATUS:-unreachable})" >&2; return 1 ;;
  esac
}

# Remove workspace by ID. Returns success even if ID not present (DELETE is
# idempotent, matching the original).
catalog_workspace_remove() {
  local id="$1"
  _catalog_req DELETE "/v1/workspaces/$id" >/dev/null
  return 0
}

# Bump last_used_at. Returns success even if ID missing (best-effort, as before).
catalog_workspace_touch() {
  local id="$1"
  _catalog_req POST "/v1/workspaces/$id/touch" >/dev/null
  return 0
}

# ---- client-local: devpod context + per-machine workspace.json -------------
# (Identical to the original; these are this-machine facts, not catalog data.)

catalog_devpod_context() {
  if ! command -v devpod >/dev/null 2>&1; then
    echo "default"; return 0
  fi
  local ctx
  ctx=$(devpod context list --output json 2>/dev/null \
        | jq -r '.[] | select(.default == true) | .name' 2>/dev/null)
  echo "${ctx:-default}"
}

catalog_devpod_workspace_json_path() {
  local id="$1" ctx
  ctx=$(catalog_devpod_context)
  echo "$HOME/.devpod/contexts/$ctx/workspaces/$id/workspace.json"
}

# Snapshot devpod's local workspace.json (this machine) into the catalog entry
# via the service: PATCH {uid, devpod_state}. Mirrors the original's local read
# of `.uid` from the client-side file.
catalog_workspace_set_devpod_state() {
  local id="$1" path snapshot uid payload
  path=$(catalog_devpod_workspace_json_path "$id")
  if [[ ! -f "$path" ]]; then
    echo "catalog_workspace_set_devpod_state: $path not found" >&2
    return 1
  fi
  if ! snapshot=$(jq -e . "$path" 2>/dev/null); then
    echo "catalog_workspace_set_devpod_state: $path is not valid JSON" >&2
    return 1
  fi
  uid=$(jq -r '.uid // empty' <<<"$snapshot")
  if [[ -n "$uid" ]]; then
    payload=$(jq -n --arg uid "$uid" --argjson state "$snapshot" \
      '{uid:$uid, devpod_state:$state}')
  else
    payload=$(jq -n --argjson state "$snapshot" '{devpod_state:$state}')
  fi
  _catalog_req PATCH "/v1/workspaces/$id" "$payload" >/dev/null || true
  [[ "$DVW_CAT_STATUS" =~ ^2 ]] || {
    echo "catalog_workspace_set_devpod_state: PATCH failed for $id (status ${DVW_CAT_STATUS:-unreachable})" >&2
    return 1
  }
}

catalog_workspace_get_devpod_state() {
  local id="$1" body
  body=$(catalog_workspace_get "$id") || return 1
  jq -e '.devpod_state // empty | select(. != null and . != {})' <<<"$body" \
    >/dev/null 2>&1 || { echo "catalog_workspace_get_devpod_state: no snapshot for $id" >&2; return 1; }
  jq '.devpod_state' <<<"$body"
}

catalog_workspace_get_uid() {
  local id="$1" body
  body=$(catalog_workspace_get "$id" 2>/dev/null) || return 0
  jq -r '.uid // empty' <<<"$body"
}

# ---- repos -----------------------------------------------------------------

catalog_repo_upsert() {
  local url="$1" branch="$2" payload
  payload=$(jq -n --arg url "$url" --arg branch "$branch" \
    '{url:$url, last_branch:$branch}')
  _catalog_req POST /v1/repos "$payload" >/dev/null || true
  [[ "$DVW_CAT_STATUS" =~ ^2 ]]
}

catalog_repo_list() {
  local body
  body=$(_catalog_req GET /v1/repos) || return 1
  jq -r '.[].url' <<<"$body"
}

catalog_repo_last_branch() {
  local url="$1" enc body rc
  enc=$(jq -rn --arg u "$url" '$u|@uri')
  body=$(_catalog_req GET "/v1/repos/by-url?url=$enc"); rc=$?
  [[ $rc -eq 0 ]] || return 0   # not found -> empty, like the original
  jq -r '.last_branch // empty' <<<"$body"
}

catalog_default() {
  local key="$1" body
  body=$(_catalog_req GET /v1/defaults) || return 1
  jq -r --arg k "$key" '.[$k] // ""' <<<"$body"
}
