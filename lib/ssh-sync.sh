#!/usr/bin/env bash
# SSH config blueprint sync. Mirrors the catalog model: a single source of
# truth in ~/Dropbox-remote/dvw/, refreshed into a local copy on dvw startup.
# Local ~/.ssh/config gains an `Include` line and is otherwise untouched.

DVW_SSH_BLUEPRINT_DEFAULT="$HOME/Dropbox-remote/dvw/ssh-blueprint.conf"
DVW_SSH_LOCAL="$HOME/.ssh/dvw.conf"
DVW_SSH_CONFIG="$HOME/.ssh/config"
DVW_SSH_INCLUDE_LINE='Include "dvw.conf"'

ssh_sync_blueprint_path() {
  echo "${DVW_SSH_BLUEPRINT:-$DVW_SSH_BLUEPRINT_DEFAULT}"
}

# Seed content used when no blueprint exists yet (first-time install).
_ssh_sync_seed_blueprint() {
  cat <<'CONF'
# dvw blueprint — synced from ~/Dropbox-remote/dvw/ssh-blueprint.conf.
# Edit there; all machines pick it up on the next `dvw` invocation.
# Personal/host-specific config stays in ~/.ssh/config; only put shared
# config here.

Host *.devpod
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
CONF
}

# Refresh local copy from blueprint if blueprint is newer (or local missing).
# Silently no-op if the blueprint is unreachable (mount down, first run).
ssh_sync_refresh() {
  local blueprint
  blueprint=$(ssh_sync_blueprint_path)
  [[ -f "$blueprint" ]] || return 0

  if [[ ! -f "$DVW_SSH_LOCAL" ]]; then
    cp -- "$blueprint" "$DVW_SSH_LOCAL"
  else
    local b_mtime l_mtime
    b_mtime=$(stat -c %Y "$blueprint" 2>/dev/null || echo 0)
    l_mtime=$(stat -c %Y "$DVW_SSH_LOCAL" 2>/dev/null || echo 0)
    if (( b_mtime > l_mtime )); then
      cp -- "$blueprint" "$DVW_SSH_LOCAL"
    fi
  fi

  # Always re-assert mode 600. Cheap, and self-heals an earlier botched
  # install (e.g. cp -p failure leaving the file at the umask default).
  chmod 600 "$DVW_SSH_LOCAL" 2>/dev/null || true
}

# One-shot bootstrap, idempotent. Called by dvw-install.sh.
ssh_sync_init() {
  local blueprint
  blueprint=$(ssh_sync_blueprint_path)
  local blueprint_dir
  blueprint_dir=$(dirname "$blueprint")

  if [[ ! -d "$blueprint_dir" ]]; then
    echo "ssh_sync_init: $blueprint_dir does not exist (rclone mount down?)" >&2
    return 1
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Only chmod if we just created the file — don't silently tighten an
  # existing user-managed config.
  if [[ ! -f "$DVW_SSH_CONFIG" ]]; then
    : > "$DVW_SSH_CONFIG"
    chmod 600 "$DVW_SSH_CONFIG"
  fi

  if [[ ! -f "$blueprint" ]]; then
    _ssh_sync_seed_blueprint > "$blueprint"
  fi

  ssh_sync_refresh

  _ssh_sync_ensure_include_at_top
}

# Ensure `Include "dvw.conf"` sits at the top of ~/.ssh/config, above any
# Host block. SSH propagates the enclosing Host block's activep flag into
# Includes, so an Include inside a non-matching Host block silently
# shadows its content for the queried hostname. Top-of-file = no
# enclosing Host = activep=TRUE for the include's content.
_ssh_sync_ensure_include_at_top() {
  local first_host first_include
  first_host=$(grep -nE '^Host[[:space:]]' "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
  first_include=$(grep -nF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)

  # Already at the top (before any Host block, or no Host block exists).
  if [[ -n "$first_include" ]] && { [[ -z "$first_host" ]] || (( first_include < first_host )); }; then
    return 0
  fi

  # Either missing entirely, or sitting after a Host block. Strip any
  # existing copies of the line + its managed-by comment, then prepend.
  local tmp
  tmp=$(mktemp)
  grep -vE '^# dvw — managed by lib/ssh-sync\.sh|^Include "dvw\.conf"$' "$DVW_SSH_CONFIG" > "$tmp" || true
  {
    echo "# dvw — managed by lib/ssh-sync.sh; edit ~/Dropbox-remote/dvw/ssh-blueprint.conf"
    echo "$DVW_SSH_INCLUDE_LINE"
    echo ""
    cat "$tmp"
  } > "$DVW_SSH_CONFIG"
  rm -f "$tmp"
}

# Three [OK]/[WARN]/[FAIL] lines for `dvw doctor`. Returns 0 always —
# config drift is a soft warning, not stop-the-world.
ssh_sync_doctor() {
  local blueprint
  blueprint=$(ssh_sync_blueprint_path)

  if [[ -f "$blueprint" ]]; then
    ui_status_ok "ssh blueprint: $blueprint"
  else
    ui_status_warn "ssh blueprint: $blueprint not present (mount down, or never installed)"
  fi

  if [[ -f "$DVW_SSH_LOCAL" ]]; then
    local mode b_mtime l_mtime
    mode=$(stat -c %a "$DVW_SSH_LOCAL" 2>/dev/null || echo "?")
    if [[ "$mode" != "600" ]]; then
      ui_status_warn "ssh local copy: $DVW_SSH_LOCAL has mode $mode (should be 600)"
    elif [[ -f "$blueprint" ]]; then
      b_mtime=$(stat -c %Y "$blueprint" 2>/dev/null || echo 0)
      l_mtime=$(stat -c %Y "$DVW_SSH_LOCAL" 2>/dev/null || echo 0)
      if (( b_mtime > l_mtime )); then
        ui_status_warn "ssh local copy: $DVW_SSH_LOCAL is older than blueprint (run \`dvw -l\` to refresh)"
      else
        ui_status_ok "ssh local copy: $DVW_SSH_LOCAL"
      fi
    else
      ui_status_ok "ssh local copy: $DVW_SSH_LOCAL (blueprint unreachable, can't compare mtime)"
    fi
  else
    ui_status_warn "ssh local copy: $DVW_SSH_LOCAL missing — run dvw-install.sh"
  fi

  if [[ -f "$DVW_SSH_CONFIG" ]] && grep -qF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG"; then
    local first_host first_include
    first_host=$(grep -nE '^Host[[:space:]]' "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    first_include=$(grep -nF "$DVW_SSH_INCLUDE_LINE" "$DVW_SSH_CONFIG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -z "$first_host" ]] || (( first_include < first_host )); then
      ui_status_ok "ssh include: $DVW_SSH_CONFIG references dvw.conf (positioned above any Host block)"
    else
      ui_status_warn "ssh include: dvw.conf Include is BELOW a Host block (line $first_include after line $first_host) — run dvw-install.sh to relocate; SSH shadows Includes inside non-matching Host blocks"
    fi
  else
    ui_status_warn "ssh include: $DVW_SSH_CONFIG does not contain $DVW_SSH_INCLUDE_LINE — run dvw-install.sh"
  fi

  return 0
}
