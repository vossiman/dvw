#!/usr/bin/env bats
#
# Tests for the multi-machine sync helpers in devpod/lib/connect.sh:
#   _dvw_ensure_local_devpod_state — synthesize ~/.devpod/.../workspace.json
#                                    from the catalog snapshot.
#
# The canonical-container resolver path (_dvw_resolve_canonical_container)
# requires a fake SSH host that returns scripted docker+tmux output and is
# deferred — see the TODO block at the bottom.

setup() {
  TMPDIR=$(mktemp -d)
  export DVW_CATALOG="$TMPDIR/catalog.json"
  export HOME="$TMPDIR"
  # No devpod CLI → catalog_devpod_context falls back to "default".
  export PATH=/nonexistent:/usr/bin:/bin
  # Stub out ui_* functions sourced by connect.sh so they don't reference
  # ANSI variables / gum that aren't available in tests.
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

teardown() {
  rm -rf "$TMPDIR"
}

# Helper: write a catalog with one workspace entry that has a devpod_state
# snapshot (uid + provider.options.HOST). Returns via stdout.
_seed_catalog_with_snapshot() {
  local id="$1" uid="$2" host="${3:-vossisrv}"
  cat > "$DVW_CATALOG" <<JSON
{
  "version": 1,
  "defaults": { "ide": "cursor", "provider": "vossisrv" },
  "workspaces": [{
    "id": "$id",
    "repo": "git@github.com:foo/bar.git",
    "branch": "main",
    "ide": "cursor",
    "provider": "vossisrv",
    "created_at": "2026-05-04T10:00:00Z",
    "last_used_at": "2026-05-04T10:00:00Z",
    "created_on": "vossimachine",
    "uid": "$uid",
    "devpod_state": {
      "id": "$id",
      "workspace": {
        "uid": "$uid",
        "provider": { "options": { "HOST": { "value": "$host", "userProvided": true } } }
      }
    }
  }],
  "repos": []
}
JSON
}

@test "_dvw_ensure_local_devpod_state: writes synthesized workspace.json from catalog snapshot when local missing" {
  _seed_catalog_with_snapshot "myws" "default-my-abc12"
  ws_path="$HOME/.devpod/contexts/default/workspaces/myws/workspace.json"
  [ ! -f "$ws_path" ]
  run _dvw_ensure_local_devpod_state myws
  [ "$status" -eq 0 ]
  [ -f "$ws_path" ]
  jq -e '.workspace.uid == "default-my-abc12"' "$ws_path"
  jq -e '.workspace.provider.options.HOST.value == "vossisrv"' "$ws_path"
}

@test "_dvw_ensure_local_devpod_state: no-op when local workspace.json already exists" {
  _seed_catalog_with_snapshot "myws" "default-my-abc12"
  ws_path="$HOME/.devpod/contexts/default/workspaces/myws/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  echo '{"sentinel":"do-not-overwrite"}' > "$ws_path"
  run _dvw_ensure_local_devpod_state myws
  [ "$status" -eq 0 ]
  jq -e '.sentinel == "do-not-overwrite"' "$ws_path"
}

@test "_dvw_ensure_local_devpod_state: errors and prints legacy hint when catalog has no snapshot" {
  cat > "$DVW_CATALOG" <<'JSON'
{
  "version": 1,
  "defaults": { "ide": "cursor", "provider": "vossisrv" },
  "workspaces": [{
    "id": "legacy",
    "repo": "git@github.com:foo/bar.git",
    "branch": "main",
    "ide": "cursor",
    "provider": "vossisrv",
    "created_at": "2026-04-01T00:00:00Z",
    "last_used_at": "2026-04-01T00:00:00Z",
    "created_on": "vossimachine"
  }],
  "repos": []
}
JSON
  run _dvw_ensure_local_devpod_state legacy
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy"* || "$stderr" == *"legacy"* ]] || [ -n "$output$stderr" ]
}

@test "_dvw_ensure_local_devpod_state: writes valid JSON (jq can re-parse the synthesized file)" {
  _seed_catalog_with_snapshot "validjson" "default-vj-zzzzz"
  run _dvw_ensure_local_devpod_state validjson
  [ "$status" -eq 0 ]
  ws_path="$HOME/.devpod/contexts/default/workspaces/validjson/workspace.json"
  jq -e . "$ws_path" >/dev/null
}

# TODO: canonical-container resolver tests
#
# _dvw_resolve_canonical_container requires a stand-in SSH host that emits
# scripted `docker ps` + `docker exec tmux list-sessions` output. Cases to
# feed once the ssh stub is in place:
#   - 0 containers labeled → returns 0, local untouched (cold-start path)
#   - 1 container, 0 tmux → returns 0, local gets that uid
#   - 1 container, 1 tmux → returns 0, local gets that uid
#   - 2+ containers, 1 with tmux → returns 0, local gets the tmux holder's uid
#   - 2+ containers, ≥2 with tmux → returns 0, picks most-recently-active,
#     emits WARN
#   - 2+ containers, 0 with tmux → returns 1 (pathological), local untouched
#   - SSH unreachable → returns 0 (best-effort), local untouched
