#!/usr/bin/env bash
# Service-backed implementation of dvw's ssh-blueprint sync (was a Dropbox file).
#
# Same functions (ssh_sync_refresh / ssh_sync_init / ssh_sync_doctor /
# ssh_sync_blueprint_path) and the same local-file behavior (~/.ssh/dvw.conf +
# a top-of-file Include in ~/.ssh/config). The single source of truth is now
# the service's GET/PUT /v1/blueprint instead of a Dropbox-synced file.

_SSH_SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=catalog-http-lib.sh
. "$_SSH_SYNC_LIB_DIR/catalog-http-lib.sh"

DVW_SSH_LOCAL="$HOME/.ssh/dvw.conf"
DVW_SSH_CONFIG="$HOME/.ssh/config"
DVW_SSH_INCLUDE_LINE='Include "dvw.conf"'

ssh_sync_blueprint_path() {
  echo "service://${DVW_CATALOG_HOST}/v1/blueprint"
}

# Fetch the blueprint from the service and refresh the local copy if it differs.
# Silent no-op if the service is unreachable (matches original's mount-down case).
ssh_sync_refresh() {
  local body content
  body=$(_catalog_req GET /v1/blueprint) || return 0
  content=$(jq -r '.content' <<<"$body" 2>/dev/null) || return 0
  [[ -z "$content" ]] && return 0

  if [[ ! -f "$DVW_SSH_LOCAL" ]] || [[ "$content" != "$(cat "$DVW_SSH_LOCAL")" ]]; then
    printf '%s' "$content" > "$DVW_SSH_LOCAL"
  fi
  chmod 600 "$DVW_SSH_LOCAL" 2>/dev/null || true
}

# One-shot bootstrap, idempotent. Seeds the server blueprint if none exists yet.
ssh_sync_init() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ ! -f "$DVW_SSH_CONFIG" ]]; then
    : > "$DVW_SSH_CONFIG"
    chmod 600 "$DVW_SSH_CONFIG"
  fi

  # If the server has no blueprint yet (version 0 = seed), persist the seed so
  # it becomes the durable source of truth.
  local body ver
  body=$(_catalog_req GET /v1/blueprint) || { echo "ssh_sync_init: catalog service unreachable" >&2; return 1; }
  ver=$(jq -r '.version' <<<"$body" 2>/dev/null)
  if [[ "$ver" == "0" ]]; then
    local seed payload
    seed=$(jq -r '.content' <<<"$body")
    payload=$(jq -n --arg c "$seed" '{content:$c}')
    _catalog_req PUT /v1/blueprint "$payload" >/dev/null
  fi

  ssh_sync_refresh
  _ssh_sync_ensure_include_at_top
}

# Ensure `Include "dvw.conf"` sits at the very top of ~/.ssh/config, above any
# Host block. (Verbatim from the original — SSH shadows Includes nested inside
# non-matching Host blocks.)
_ssh_sync_ensure_include_at_top() {
  local first_host first_include
  first_host=$(grep -nE '^Host[[:space:]]' "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
  first_include=$(grep -nF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)

  if [[ -n "$first_include" ]] && { [[ -z "$first_host" ]] || (( first_include < first_host )); }; then
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  grep -vE '^# dvw — managed by lib/ssh-sync\.sh|^Include "dvw\.conf"$' "$DVW_SSH_CONFIG" > "$tmp" || true
  {
    echo "# dvw — managed by lib/ssh-sync.sh; edit via the catalog service (PUT /v1/blueprint)"
    echo "$DVW_SSH_INCLUDE_LINE"
    echo ""
    cat "$tmp"
  } > "$DVW_SSH_CONFIG"
  rm -f "$tmp"
}

# Three [OK]/[WARN] lines for `dvw doctor`. Returns 0 always.
ssh_sync_doctor() {
  if _catalog_req GET /v1/blueprint >/dev/null 2>&1; then
    ui_status_ok "ssh blueprint: served by catalog ($(ssh_sync_blueprint_path))"
  else
    ui_status_warn "ssh blueprint: catalog service unreachable"
  fi

  if [[ -f "$DVW_SSH_LOCAL" ]]; then
    local mode
    mode=$(stat -c %a "$DVW_SSH_LOCAL" 2>/dev/null || echo "?")
    if [[ "$mode" != "600" ]]; then
      ui_status_warn "ssh local copy: $DVW_SSH_LOCAL has mode $mode (should be 600)"
    else
      ui_status_ok "ssh local copy: $DVW_SSH_LOCAL"
    fi
  else
    ui_status_warn "ssh local copy: $DVW_SSH_LOCAL missing — run dvw-install.sh"
  fi

  if [[ -f "$DVW_SSH_CONFIG" ]] && grep -qF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG"; then
    local first_host first_include
    first_host=$(grep -nE '^Host[[:space:]]' "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    first_include=$(grep -nF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -z "$first_host" ]] || (( first_include < first_host )); then
      ui_status_ok "ssh include: $DVW_SSH_CONFIG references dvw.conf (above any Host block)"
    else
      ui_status_warn "ssh include: dvw.conf Include is BELOW a Host block — run dvw-install.sh to relocate"
    fi
  else
    ui_status_warn "ssh include: $DVW_SSH_CONFIG does not contain $DVW_SSH_INCLUDE_LINE — run dvw-install.sh"
  fi

  return 0
}
