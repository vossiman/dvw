#!/usr/bin/env bats
#
# Tests for the multi-machine sync helper in devpod/lib/connect.sh:
#   _dvw_ensure_local_devpod_state — synthesize this machine's local
#     ~/.devpod/.../workspace.json from the catalog's devpod_state snapshot.
#
# The snapshot now comes from the catalog SERVICE: _dvw_ensure_local_devpod_state
# calls catalog_workspace_get_devpod_state, which GETs /v1/workspaces/{id} and
# extracts .devpod_state. We serve that response via the transport stub
# (tests/bats/lib/catalog-stub.bash); the synthesized local file is real.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  # PATH keeps the stub first; no devpod CLI on it → catalog_devpod_context
  # falls back to "default".
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export DVW_CATALOG_HOST=stub
  export DVW_CATALOG_SOCK="$TMPDIR/not-a-socket.sock"
  load "lib/catalog-stub.bash"

  ui_error()        { echo "ERROR: $*" >&2; }
  ui_info()         { echo "INFO: $*" >&2; }
  ui_action()       { echo "ACTION: $*" >&2; }
  ui_status_ok()    { echo "OK: $*" >&2; }
  ui_status_warn()  { echo "WARN: $*" >&2; }
  ui_status_fail()  { echo "FAIL: $*" >&2; }
  export -f ui_error ui_info ui_action ui_status_ok ui_status_warn ui_status_fail
}

teardown() {
  rm -rf "$TMPDIR"
}

# Serve a workspace whose response carries a devpod_state snapshot (uid +
# provider.options.HOST) for <id>; everything else 404. devpod CLI is absent so
# catalog_devpod_context resolves to "default" and the local path is
# $HOME/.devpod/contexts/default/workspaces/<id>/workspace.json.
_serve_workspace_with_snapshot() {
  local id="$1" uid="$2" host="${3:-vossisrv}"
  export STUB_WS_ID="$id" STUB_WS_UID="$uid" STUB_WS_HOST="$host"
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/$STUB_WS_ID")
        _stub_emit "{
          \"id\": \"$STUB_WS_ID\",
          \"uid\": \"$STUB_WS_UID\",
          \"devpod_state\": {
            \"id\": \"$STUB_WS_ID\",
            \"workspace\": {
              \"uid\": \"$STUB_WS_UID\",
              \"provider\": { \"options\": { \"HOST\": { \"value\": \"$STUB_WS_HOST\", \"userProvided\": true } } }
            }
          }
        }" 200 ;;
      *) _stub_emit '{"error":{"code":"not_found"}}' 404 ;;
    esac
  }
  catalog_stub_install
}

@test "_dvw_ensure_local_devpod_state: writes synthesized workspace.json from catalog snapshot when local missing" {
  _serve_workspace_with_snapshot "myws" "default-my-abc12"
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  ws_path="$HOME/.devpod/contexts/default/workspaces/myws/workspace.json"
  [ ! -f "$ws_path" ]
  run _dvw_ensure_local_devpod_state myws
  [ "$status" -eq 0 ]
  [ -f "$ws_path" ]
  jq -e '.workspace.uid == "default-my-abc12"' "$ws_path"
  jq -e '.workspace.provider.options.HOST.value == "vossisrv"' "$ws_path"
}

@test "_dvw_ensure_local_devpod_state: no-op when local workspace.json already exists" {
  # Local file present → returns before any service call.
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  ws_path="$HOME/.devpod/contexts/default/workspaces/myws/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  echo '{"sentinel":"do-not-overwrite"}' > "$ws_path"
  run _dvw_ensure_local_devpod_state myws
  [ "$status" -eq 0 ]
  jq -e '.sentinel == "do-not-overwrite"' "$ws_path"
}

@test "_dvw_ensure_local_devpod_state: errors and prints legacy hint when catalog has no snapshot" {
  # Workspace exists in the catalog but carries no devpod_state snapshot.
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/legacy") _stub_emit '{"id":"legacy","provider":"vossisrv"}' 200 ;;
      *)                           _stub_emit '{"error":{"code":"not_found"}}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  run _dvw_ensure_local_devpod_state legacy
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy"* ]]
}

@test "_dvw_ensure_local_devpod_state: writes valid JSON (jq can re-parse the synthesized file)" {
  _serve_workspace_with_snapshot "validjson" "default-vj-zzzzz"
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  run _dvw_ensure_local_devpod_state validjson
  [ "$status" -eq 0 ]
  ws_path="$HOME/.devpod/contexts/default/workspaces/validjson/workspace.json"
  jq -e . "$ws_path" >/dev/null
}

# TODO: canonical-container resolver tests (_dvw_resolve_canonical_container,
# now lib/connect-resolver.sh → GET /v1/workspaces/{id}/container). Feed the
# stub container responses for: no container (cold), single container align,
# ambiguous (status 1), uid-claimed-by-other refusal, service unreachable.
