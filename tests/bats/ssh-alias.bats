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
  [[ "$output" == *'ProxyCommand "/home/u/.local/bin/devpod" ssh --stdio --agent-forwarding=false --context default --user codespace myws'* ]]
  [[ "$output" == *"User codespace"* ]]
}

@test "_dvw_render_ssh_alias_block: threads context and user through" {
  run _dvw_render_ssh_alias_block other vossi prod /bin/devpod
  [[ "$output" == *"--agent-forwarding=false --context prod --user vossi other"* ]]
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

# The workstation agent holds every passphrase-less key in ~/.ssh; forwarding
# it hands all of them to every process in the container. Both lines below are
# load-bearing: `devpod ssh` forwards over its own transport with
# --agent-forwarding defaulting to true, so ForwardAgent no alone leaves the
# agent reachable. Assert the effective ssh -G value, not just the directive.
@test "_dvw_render_ssh_alias_block: agent forwarding is off in BOTH channels" {
  block=$(_dvw_render_ssh_alias_block myws codespace default /bin/true)
  [[ "$block" == *"--agent-forwarding=false"* ]]
  [[ "$block" != *"ForwardAgent yes"* ]]

  cfg="$TMPDIR/.ssh/agent-fwd-check"
  printf '%s\n' "$block" > "$cfg"
  run "$REAL_SSH" -F "$cfg" -G myws.devpod
  [ "$status" -eq 0 ]
  [[ "$output" == *"forwardagent no"* ]]
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

# Helper: stub out ssh + devpod so _dvw_ensure_ssh_alias can resolve a binary.
_stub_ssh_and_devpod() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/ssh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/devpod"
  chmod +x "$STUB_BIN/ssh" "$STUB_BIN/devpod"
}

@test "_dvw_ensure_ssh_alias: existing block is reconciled, never duplicated" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  User sentinel
# DevPod End myws.devpod
EOF
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '# DevPod Start myws.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
  # The existing User is authoritative (resolve tier 1) and survives.
  grep -q "User sentinel" "$DVW_SSH_CONFIG"
}

# THE REGRESSION THIS PR EXISTS FOR. `devpod up --configure-ssh` defaults true
# and rewrites its own stanza with `ForwardAgent yes` and no
# --agent-forwarding=false, undoing #48 on every container start. Reconcile
# must repair that, or the fix is decorative.
@test "_dvw_ensure_ssh_alias: repairs a DevPod-written block that re-enabled agent forwarding" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  ForwardAgent yes
  LogLevel error
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  HostKeyAlgorithms rsa-sha2-256,rsa-sha2-512,ssh-rsa
  ProxyCommand "/home/u/.local/bin/devpod" ssh --stdio --context default --user codespace myws
  User codespace
# DevPod End myws.devpod
EOF
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '# DevPod Start myws.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
  ! grep -q "ForwardAgent yes" "$DVW_SSH_CONFIG"
  grep -q -- "--agent-forwarding=false" "$DVW_SSH_CONFIG"
  # Assert the EFFECTIVE value, not the directive text.
  run "$REAL_SSH" -F "$DVW_SSH_CONFIG" -G myws.devpod
  [ "$status" -eq 0 ]
  [[ "$output" == *"forwardagent no"* ]]
}

@test "_dvw_ensure_ssh_alias: reconcile replaces IN PLACE, preserving position and neighbours" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  cat > "$DVW_SSH_CONFIG" <<'EOF'
Host before-marker
  User alice
# DevPod Start myws.devpod
Host myws.devpod
  ForwardAgent yes
  User codespace
# DevPod End myws.devpod
Host after-marker
  User bob
EOF
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  # Neighbours intact...
  grep -q "Host before-marker" "$DVW_SSH_CONFIG"
  grep -q "Host after-marker" "$DVW_SSH_CONFIG"
  # ...and the block did not migrate to the end of the file.
  before=$(grep -n "Host before-marker" "$DVW_SSH_CONFIG" | cut -d: -f1)
  start=$(grep -n "# DevPod Start myws.devpod" "$DVW_SSH_CONFIG" | cut -d: -f1)
  after=$(grep -n "Host after-marker" "$DVW_SSH_CONFIG" | cut -d: -f1)
  [ "$before" -lt "$start" ]
  [ "$start" -lt "$after" ]
}

@test "_dvw_ensure_ssh_alias: a conforming block is left byte-identical" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  run _dvw_ensure_ssh_alias myws          # first call writes it
  [ "$status" -eq 0 ]
  cp "$DVW_SSH_CONFIG" "$TMPDIR/expected"
  run _dvw_ensure_ssh_alias myws          # second call must change nothing
  [ "$status" -eq 0 ]
  diff -q "$TMPDIR/expected" "$DVW_SSH_CONFIG"
}

@test "_dvw_ensure_ssh_alias: reconcile leaves a prefix-sharing id untouched" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  ForwardAgent yes
  User codespace
# DevPod End myws.devpod
# DevPod Start myws-two.devpod
Host myws-two.devpod
  ForwardAgent yes
  User codespace
# DevPod End myws-two.devpod
EOF
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  # The sibling keeps its own (stale) block — we only reconcile the id asked for.
  run awk '/# DevPod Start myws-two.devpod/,/# DevPod End myws-two.devpod/' "$DVW_SSH_CONFIG"
  [[ "$output" == *"ForwardAgent yes"* ]]
  [ "$(grep -cxF '# DevPod Start myws-two.devpod' "$DVW_SSH_CONFIG")" -eq 1 ]
}

@test "_dvw_ensure_ssh_alias: reconciled file is still mode 600" {
  _write_local_workspace_json myws default-my-abc12 vossisrv
  _stub_ssh_and_devpod
  cat > "$DVW_SSH_CONFIG" <<'EOF'
# DevPod Start myws.devpod
Host myws.devpod
  ForwardAgent yes
  User codespace
# DevPod End myws.devpod
EOF
  chmod 600 "$DVW_SSH_CONFIG"
  run _dvw_ensure_ssh_alias myws
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$DVW_SSH_CONFIG")" = "600" ]
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
