#!/usr/bin/env bash
# Windows/Cursor SSH bridge. When dvw runs inside WSL, ensure the Windows-side
# ~/.ssh/config has an Include for a managed dvw.conf that routes *.devpod
# hosts through wsl.exe -> devpod ssh --stdio. Lets Cursor (and any other
# Windows-native SSH client) reach DevPod workspaces without per-workspace
# config sync. No-op outside WSL.

DVW_WSL_BRIDGE_INCLUDE_LINE='Include "dvw.conf"'
DVW_WSL_BRIDGE_HOME_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dvw/win-home"

wsl_bridge_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null
}

# Resolve %USERPROFILE% as a WSL path. Cached because cmd.exe spawn is ~150ms.
wsl_bridge_windows_home() {
  if [[ -f "$DVW_WSL_BRIDGE_HOME_CACHE" ]]; then
    local cached
    cached=$(<"$DVW_WSL_BRIDGE_HOME_CACHE")
    if [[ -d "$cached" ]]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi

  command -v wslpath >/dev/null 2>&1 || return 1

  # cmd.exe is on PATH when WSL interop auto-appends Windows paths, but
  # subshells (e.g. invoked from non-interactive scripts) may not inherit
  # that. Fall back to the canonical /mnt/c install path.
  local cmd_exe
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd_exe=cmd.exe
  elif [[ -x /mnt/c/Windows/System32/cmd.exe ]]; then
    cmd_exe=/mnt/c/Windows/System32/cmd.exe
  else
    return 1
  fi

  local win_path unix_path
  win_path=$("$cmd_exe" /C 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
  [[ -n "$win_path" ]] || return 1
  unix_path=$(wslpath -u "$win_path" 2>/dev/null) || return 1
  [[ -d "$unix_path" ]] || return 1

  mkdir -p "$(dirname "$DVW_WSL_BRIDGE_HOME_CACHE")"
  printf '%s\n' "$unix_path" > "$DVW_WSL_BRIDGE_HOME_CACHE"
  printf '%s\n' "$unix_path"
}

# Wildcard block. Mirrors the per-workspace stanza DevPod injects on the WSL
# side (HostKeyAlgorithms, UserKnownHostsFile, User=codespace). %h is the
# user-typed alias because we deliberately do not set HostName; the helper
# strips the .devpod suffix before handing off to devpod ssh --stdio.
_wsl_bridge_seed_block() {
  local helper="$1"
  cat <<CONF
# Managed by dvw — do not edit. Routes *.devpod via WSL's devpod CLI.
Host *.devpod
  ForwardAgent yes
  LogLevel error
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  HostKeyAlgorithms rsa-sha2-256,rsa-sha2-512,ssh-rsa
  ServerAliveInterval 30
  User codespace
  ProxyCommand wsl.exe -e $helper %h
CONF
}

# Top-of-file Include, mirroring _ssh_sync_ensure_include_at_top in ssh-sync.sh.
# An Include nested inside a non-matching Host block is silently shadowed for
# the queried hostname, so position matters.
_wsl_bridge_ensure_include_at_top() {
  local cfg="$1"
  local first_host first_include
  first_host=$(grep -nE '^Host[[:space:]]' "$cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)
  first_include=$(grep -nF "$DVW_WSL_BRIDGE_INCLUDE_LINE" "$cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)

  if [[ -n "$first_include" ]] && { [[ -z "$first_host" ]] || (( first_include < first_host )); }; then
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  grep -vE '^# dvw — managed by devpod/lib/wsl-bridge\.sh|^Include "dvw\.conf"$' "$cfg" > "$tmp" || true
  {
    echo "# dvw — managed by devpod/lib/wsl-bridge.sh; routes *.devpod through WSL"
    echo "$DVW_WSL_BRIDGE_INCLUDE_LINE"
    echo ""
    cat "$tmp"
  } > "$cfg"
  rm -f "$tmp"
}

# Idempotent: writes dvw.conf only when content changed; ensures Include is at
# the top of Windows ~/.ssh/config. Silent no-op on non-WSL or when Windows
# home can't be resolved.
wsl_bridge_refresh() {
  wsl_bridge_is_wsl || return 0

  local win_home
  win_home=$(wsl_bridge_windows_home) || return 0

  local ssh_dir="$win_home/.ssh"
  local target="$ssh_dir/dvw.conf"
  local config="$ssh_dir/config"

  mkdir -p "$ssh_dir"

  # Helper lives next to this lib file. Resolve via the lib's own location so
  # we don't depend on the caller having $DVW_ROOT in scope.
  local helper="${BASH_SOURCE[0]%/*}/win-ssh-proxy.sh"
  [[ -x "$helper" ]] || chmod +x "$helper" 2>/dev/null || true

  local desired
  desired=$(_wsl_bridge_seed_block "$helper")
  if [[ ! -f "$target" ]] || ! printf '%s\n' "$desired" | diff -q - "$target" >/dev/null 2>&1; then
    printf '%s\n' "$desired" > "$target"
  fi

  [[ -f "$config" ]] || : > "$config"
  _wsl_bridge_ensure_include_at_top "$config"
}
