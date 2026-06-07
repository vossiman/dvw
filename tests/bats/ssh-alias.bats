#!/usr/bin/env bats
#
# Tests for the per-workspace SSH alias writer in devpod/dvw/lib/connect.sh:
#   _dvw_devpod_bin, _dvw_ssh_alias_present, _dvw_render_ssh_alias_block,
#   _dvw_resolve_ssh_user, _dvw_ensure_ssh_alias, _dvw_alias_defined.
#
# All tests run against a sandbox HOME; no real ~/.ssh/config or container
# is ever touched. `ssh` and `devpod` are stubbed via PATH where needed.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  # Catalog transport points at a non-socket so any accidental HTTP call fails
  # fast rather than reaching a real service; these tests never need it — the
  # ssh-alias path reads only this machine's local workspace.json.
  export DVW_CATALOG_HOST=stub
  export DVW_CATALOG_SOCK="$TMPDIR/not-a-socket.sock"
  export DVW_SSH_CONFIG="$TMPDIR/.ssh/config"
  mkdir -p "$TMPDIR/.ssh"
  # Capture the real ssh path before we shadow it via the stub dir.
  REAL_SSH=$(command -v ssh || echo /usr/bin/ssh)
  export REAL_SSH
  # Sandbox PATH: a stub bin dir first, then real coreutils/jq.
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"

  ui_error()        { echo "ERROR: $*" >&2; }
  ui_info()         { echo "INFO: $*" >&2; }
  ui_action()       { echo "ACTION: $*" >&2; }
  ui_status_ok()    { echo "OK: $*" >&2; }
  ui_status_warn()  { echo "WARN: $*" >&2; }
  ui_status_fail()  { echo "FAIL: $*" >&2; }
  export -f ui_error ui_info ui_action ui_status_ok ui_status_warn ui_status_fail

  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
}

teardown() { rm -rf "$TMPDIR"; }

# Write this machine's local devpod workspace.json directly (the 35e40dc
# pattern). The ssh-alias path is client-local: _dvw_resolve_ssh_user and
# _dvw_ensure_ssh_alias read ONLY this file (top-level .uid, .context,
# .provider.options.HOST.value), never the catalog service. Writing it here
# replaces the old "seed a catalog file then _dvw_ensure_local_devpod_state"
# dance, which depended on the now-removed local catalog file.
_write_local_workspace_json() {
  local id="$1" uid="$2" host="${3:-vossisrv}" path
  path=$(catalog_devpod_workspace_json_path "$id")
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<JSON
{
  "id": "$id",
  "uid": "$uid",
  "context": "default",
  "provider": { "options": { "HOST": { "value": "$host", "userProvided": true } } }
}
JSON
}

# ---------------------------------------------------------------------------
# _dvw_devpod_bin
# ---------------------------------------------------------------------------

@test "_dvw_devpod_bin: prefers devpod on PATH" {
  cat > "$STUB_BIN/devpod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/devpod"
  run _dvw_devpod_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$STUB_BIN/devpod" ]
}

@test "_dvw_devpod_bin: falls back to ~/.local/bin/devpod when not on PATH" {
  mkdir -p "$HOME/.local/bin"
  : > "$HOME/.local/bin/devpod"
  chmod +x "$HOME/.local/bin/devpod"
  run _dvw_devpod_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/bin/devpod" ]
}

@test "_dvw_devpod_bin: returns nonzero when nothing found" {
  run _dvw_devpod_bin
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _dvw_ssh_alias_present
# ---------------------------------------------------------------------------

@test "_dvw_ssh_alias_present: true when DevPod Start marker exists" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  User codespace
# DevPod End myws.devpod
EOF
  run _dvw_ssh_alias_present myws
  [ "$status" -eq 0 ]
}

@test "_dvw_ssh_alias_present: false when marker absent" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start other.devpod
Host other.devpod
# DevPod End other.devpod
EOF
  run _dvw_ssh_alias_present myws
  [ "$status" -ne 0 ]
}

@test "_dvw_ssh_alias_present: false when config file missing" {
  rm -f "$DVW_SSH_CONFIG"
  run _dvw_ssh_alias_present myws
  [ "$status" -ne 0 ]
}

@test "_dvw_ssh_alias_present: does not match a different id sharing a prefix" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws-extra.devpod
Host myws-extra.devpod
# DevPod End myws-extra.devpod
EOF
  run _dvw_ssh_alias_present myws
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _dvw_render_ssh_alias_block
# ---------------------------------------------------------------------------

@test "_dvw_render_ssh_alias_block: emits DevPod markers, Host, ProxyCommand, User" {
  run _dvw_render_ssh_alias_block myws codespace default /home/u/.local/bin/devpod
  [ "$status" -eq 0 ]
  [[ "$output" == *"# DevPod Start myws.devpod"* ]]
  [[ "$output" == *"# DevPod End myws.devpod"* ]]
  [[ "$output" == *"Host myws.devpod"* ]]
  [[ "$output" == *'ProxyCommand "/home/u/.local/bin/devpod" ssh --stdio --context default --user codespace myws'* ]]
  [[ "$output" == *"User codespace"* ]]
}

@test "_dvw_render_ssh_alias_block: threads context and user through" {
  run _dvw_render_ssh_alias_block other vossi prod /bin/devpod
  [[ "$output" == *"--context prod --user vossi other"* ]]
  [[ "$output" == *"User vossi"* ]]
}

@test "_dvw_render_ssh_alias_block: round-trips through ssh -G (valid stanza)" {
  block=$(_dvw_render_ssh_alias_block myws codespace default /bin/true)
  cfg="$TMPDIR/.ssh/render-check"
  printf '%s\n' "$block" > "$cfg"
  run "$REAL_SSH" -F "$cfg" -G myws.devpod
  [ "$status" -eq 0 ]
  [[ "$output" == *"user codespace"* ]]
  [[ "$output" == *"proxycommand"* ]]
}

# ---------------------------------------------------------------------------
# _dvw_resolve_ssh_user
# ---------------------------------------------------------------------------

@test "_dvw_resolve_ssh_user: tier 1 — reads User from an existing local block" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  User alice
# DevPod End myws.devpod
EOF
  run _dvw_resolve_ssh_user myws
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "_dvw_resolve_ssh_user: tier 2 — reads remoteUser from provider container label" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo '[{"remoteUser":"bob"}]'
EOF
  chmod +x "$STUB_BIN/ssh"
  run _dvw_resolve_ssh_user myws
  [ "$status" -eq 0 ]
  [ "$output" = "bob" ]
}

@test "_dvw_resolve_ssh_user: tier 3 — defaults to codespace when label query yields nothing" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  run _dvw_resolve_ssh_user myws
  [ "$status" -eq 0 ]
  [ "$output" = "codespace" ]
}

@test "_dvw_resolve_ssh_user: tier 3 — defaults to codespace when ssh unreachable" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
  chmod +x "$STUB_BIN/ssh"
  run _dvw_resolve_ssh_user myws
  [ "$status" -eq 0 ]
  [ "$output" = "codespace" ]
}

# ---------------------------------------------------------------------------
# _dvw_ensure_ssh_alias
# ---------------------------------------------------------------------------

@test "_dvw_ensure_ssh_alias: writes a block when absent and lands as codespace" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  cat > "$STUB_BIN/devpod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/devpod"
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  grep -qxF "# DevPod Start myws.devpod" "$DVW_SSH_CONFIG"
  grep -qxF "# DevPod End myws.devpod" "$DVW_SSH_CONFIG"
  grep -q "User codespace" "$DVW_SSH_CONFIG"
  run "$REAL_SSH" -F "$DVW_SSH_CONFIG" -G myws.devpod
  [[ "$output" == *"proxycommand"* ]]
  [[ "$output" == *"user codespace"* ]]
}

@test "_dvw_ensure_ssh_alias: no-op when block already present (no duplicate)" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  User sentinel
# DevPod End myws.devpod
EOF
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '# DevPod Start myws.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
  grep -q "User sentinel" "$DVW_SSH_CONFIG"
}

@test "_dvw_ensure_ssh_alias: appends a separating newline (no jammed marker)" {
  printf 'Host vossisrv\n  User vossi\n  IdentitiesOnly yes' > "$DVW_SSH_CONFIG"
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  cat > "$STUB_BIN/devpod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/devpod"
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  grep -qxF "# DevPod Start myws.devpod" "$DVW_SSH_CONFIG"
  run grep -nE 'IdentitiesOnly yes.+DevPod Start' "$DVW_SSH_CONFIG"
  [ "$status" -ne 0 ]
}

@test "_dvw_ensure_ssh_alias: result file is mode 600" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/ssh"
  cat > "$STUB_BIN/devpod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/devpod"
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$DVW_SSH_CONFIG")" = "600" ]
}

@test "_dvw_ensure_ssh_alias: errors when devpod binary cannot be resolved" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  run _dvw_ensure_ssh_alias myws
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _dvw_alias_defined
# ---------------------------------------------------------------------------

@test "_dvw_alias_defined: true when a ProxyCommand alias is present" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
Host myws.devpod
  ProxyCommand /bin/true ssh --stdio myws
  User codespace
EOF
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
exec "$REAL_SSH" -F "$DVW_SSH_CONFIG" "\$@"
EOF
  chmod +x "$STUB_BIN/ssh"
  run _dvw_alias_defined myws
  [ "$status" -eq 0 ]
}

@test "_dvw_alias_defined: false when only the generic block exists" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
Host *.devpod
  ControlMaster auto
EOF
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
exec "$REAL_SSH" -F "$DVW_SSH_CONFIG" "\$@"
EOF
  chmod +x "$STUB_BIN/ssh"
  run _dvw_alias_defined myws
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _dvw_remove_ssh_alias  (symmetric inverse of _dvw_ensure_ssh_alias)
# ---------------------------------------------------------------------------

@test "_dvw_remove_ssh_alias: removes the DevPod block for <id>" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  ProxyCommand "/bin/devpod" ssh --stdio --context default --user codespace myws
  User codespace
# DevPod End myws.devpod
EOF
  run _dvw_remove_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'myws.devpod' "$DVW_SSH_CONFIG")" -eq 0 ]
}

@test "_dvw_remove_ssh_alias: no-op (success) when no block present" {
  printf 'Host vossisrv\n  User vossi\n' > "$DVW_SSH_CONFIG"
  run _dvw_remove_ssh_alias myws
  [ "$status" -eq 0 ]
  grep -q "Host vossisrv" "$DVW_SSH_CONFIG"
}

@test "_dvw_remove_ssh_alias: no-op (success) when config file missing" {
  rm -f "$DVW_SSH_CONFIG"
  run _dvw_remove_ssh_alias myws
  [ "$status" -eq 0 ]
}

@test "_dvw_remove_ssh_alias: leaves a different id sharing a prefix intact" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  User codespace
# DevPod End myws.devpod
# DevPod Start myws-extra.devpod
Host myws-extra.devpod
  User codespace
# DevPod End myws-extra.devpod
EOF
  run _dvw_remove_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '# DevPod Start myws.devpod' "$DVW_SSH_CONFIG")" -eq 0 ]
  [ "$(grep -cxF '# DevPod Start myws-extra.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
}

@test "_dvw_remove_ssh_alias: preserves surrounding content and stays mode 600" {
  cat > "$DVW_SSH_CONFIG" <<'EOF'
Host vossisrv
  User vossi
# DevPod Start myws.devpod
Host myws.devpod
  User codespace
# DevPod End myws.devpod
# DevPod Start other.devpod
Host other.devpod
  User codespace
# DevPod End other.devpod
EOF
  chmod 600 "$DVW_SSH_CONFIG"
  run _dvw_remove_ssh_alias myws
  [ "$status" -eq 0 ]
  grep -q "Host vossisrv" "$DVW_SSH_CONFIG"
  [ "$(grep -cxF '# DevPod Start other.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
  [ "$(grep -cF 'Host myws.devpod' "$DVW_SSH_CONFIG")" -eq 0 ]
  [ "$(stat -c %a "$DVW_SSH_CONFIG")" = "600" ]
}
