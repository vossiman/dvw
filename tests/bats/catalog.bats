#!/usr/bin/env bats
#
# Client-side tests for lib/catalog.sh against the dvw-catalog HTTP service.
#
# The catalog is an HTTP service reached over a unix socket
# (lib/catalog-http-lib.sh), not a local file. These tests exercise the
# CLIENT half: the service URL it advertises, the request method/path it sends,
# how it maps HTTP status to return codes, and the jq it runs on responses.
#
# The service itself (atomic writes, schema validation, MRU ordering, conflict
# detection, devpod_state opacity) is covered by catalog-service/tests/ pytest;
# those server-side concerns are intentionally NOT re-tested here.
#
# Transport is stubbed via tests/bats/lib/catalog-stub.bash: each test defines a
# `catalog_route` function answering the routes it needs.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  # Force the deterministic ssh transport branch: a non-socket path here means
  # lib/catalog-http-lib.sh runs `ssh $DVW_CATALOG_HOST -- curl …`, which the
  # stub intercepts.
  export DVW_CATALOG_HOST=stub
  export DVW_CATALOG_SOCK="$TMPDIR/not-a-socket.sock"
  load "lib/catalog-stub.bash"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "harness smoke: bats can run a trivial test" {
  [ 1 = 1 ]
}

# --- catalog_path: advertises the service URL, not a file path --------------

@test "catalog_path: reflects DVW_CATALOG_HOST and DVW_CATALOG_SOCK" {
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_path
  [ "$status" -eq 0 ]
  [ "$output" = "service://stub$DVW_CATALOG_SOCK" ]
}

@test "catalog_path: defaults to vossisrv + /run/dvw-catalog/catalog.sock when unset" {
  unset DVW_CATALOG_HOST DVW_CATALOG_SOCK
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_path
  [ "$status" -eq 0 ]
  [ "$output" = "service://vossisrv/run/dvw-catalog/catalog.sock" ]
}

# --- catalog_init_if_missing: now a service health check --------------------

@test "catalog_init_if_missing: succeeds when the service health check passes" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/health") _stub_emit '{"status":"ok"}' 200 ;;
      *)                _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_init_if_missing
  [ "$status" -eq 0 ]
}

@test "catalog_init_if_missing: fails loudly with guidance when service unreachable" {
  catalog_route() { _stub_emit '' 503; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_init_if_missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreachable"* ]]
  [[ "$output" == *"stub"* ]]
}

# --- transport: args must survive the remote shell re-parse (regressions) ----
# `ssh host <cmd>` hands <cmd> to the remote login shell, which re-parses it.
# The lib pre-quotes the command (printf %q); these pin that, since a raw arg
# with whitespace silently broke the request (dvw doctor "service unreachable").

@test "transport: -w newline status format survives the ssh remote re-parse" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/health") _stub_emit '{"status":"ok"}' 200 ;;
      *)                _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_init_if_missing
  [ "$status" -eq 0 ]
}

@test "transport: spaced 'Bearer <token>' auth header survives the ssh re-parse" {
  export DVW_CATALOG_TOKEN='s3cr3t tok3n'   # space makes word-splitting visible
  catalog_route() {   # METHOD PATH BODY AUTH — echo the auth header back as body
    case "$1 $2" in
      "GET /v1/health") _stub_emit "$4" 200 ;;
      *)                _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run _catalog_get /v1/health
  [ "$status" -eq 0 ]
  [ "$output" = "authorization: Bearer s3cr3t tok3n" ]
}

# --- catalog_read: GET /v1/catalog ------------------------------------------

@test "catalog_read: returns the catalog body from GET /v1/catalog" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/catalog") _stub_emit '{"version": 1, "workspaces": [], "repos": []}' 200 ;;
      *)                 _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_read
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version": 1'* ]]
}

@test "catalog_read: fails when the service is unreachable" {
  catalog_route() { _stub_emit '' 503; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_read
  [ "$status" -ne 0 ]
}

# --- workspaces: typed HTTP ops ---------------------------------------------

@test "catalog_workspace_ids: extracts ids in the server's (MRU) order" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces") _stub_emit '[{"id":"myrepo-feature-x"},{"id":"other-main"}]' 200 ;;
      *)                    _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_ids
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "myrepo-feature-x" ]
  [ "${lines[1]}" = "other-main" ]
}

@test "catalog_workspace_ids: empty output for an empty workspace list" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces") _stub_emit '[]' 200 ;;
      *)                    _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_ids
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "catalog_workspace_get: returns the workspace JSON for a known ID" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/myrepo-feature-x")
        _stub_emit '{"id":"myrepo-feature-x","ide":"cursor"}' 200 ;;
      *) _stub_emit '{"error":{"code":"not_found"}}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_get myrepo-feature-x
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "myrepo-feature-x"'
  echo "$output" | jq -e '.ide == "cursor"'
}

@test "catalog_workspace_get: exits non-zero on 404 for an unknown ID" {
  catalog_route() { _stub_emit '{"error":{"code":"not_found"}}' 404; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_get nonexistent
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_add: POSTs a workspace payload and succeeds on 201" {
  # Capture the POST body so we can assert the client builds it correctly.
  local capture="$TMPDIR/add-body.json"
  catalog_route() {
    case "$1 $2" in
      "POST /v1/workspaces")
        printf '%s' "$3" > "$ADD_CAPTURE"
        _stub_emit "$3" 201 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  export ADD_CAPTURE="$capture"
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_add new-ws git@github.com:foo/bar.git main cursor vossisrv testhost
  [ "$status" -eq 0 ]
  jq -e '.id == "new-ws"'          "$capture"
  jq -e '.repo == "git@github.com:foo/bar.git"' "$capture"
  jq -e '.branch == "main"'        "$capture"
  jq -e '.ide == "cursor"'         "$capture"
  jq -e '.provider == "vossisrv"'  "$capture"
  jq -e '.created_on == "testhost"' "$capture"
}

@test "catalog_workspace_add: maps a 409 to a 'already exists' failure" {
  catalog_route() {
    case "$1 $2" in
      "POST /v1/workspaces") _stub_emit '{"error":{"code":"conflict"}}' 409 ;;
      *)                     _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_add myrepo-feature-x git@github.com:foo/bar.git main cursor vossisrv testhost
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "catalog_workspace_remove: DELETEs and returns success" {
  local hit="$TMPDIR/deleted"
  catalog_route() {
    case "$1 $2" in
      "DELETE /v1/workspaces/myrepo-feature-x")
        : > "$DEL_HIT"; _stub_emit '' 204 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  export DEL_HIT="$hit"
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_remove myrepo-feature-x
  [ "$status" -eq 0 ]
  [ -f "$hit" ]
}

@test "catalog_workspace_remove: idempotent — success even on a 404" {
  catalog_route() { _stub_emit '{"error":{"code":"not_found"}}' 404; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_remove nonexistent
  [ "$status" -eq 0 ]
}

@test "catalog_workspace_touch: POSTs to the touch route and returns success" {
  local hit="$TMPDIR/touched"
  catalog_route() {
    case "$1 $2" in
      "POST /v1/workspaces/myrepo-feature-x/touch")
        : > "$TOUCH_HIT"; _stub_emit '{}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  export TOUCH_HIT="$hit"
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_touch myrepo-feature-x
  [ "$status" -eq 0 ]
  [ -f "$hit" ]
}

# --- repos ------------------------------------------------------------------

@test "catalog_repo_upsert: POSTs the repo payload and succeeds on 2xx" {
  local capture="$TMPDIR/repo-body.json"
  catalog_route() {
    case "$1 $2" in
      "POST /v1/repos") printf '%s' "$3" > "$REPO_CAPTURE"; _stub_emit "$3" 200 ;;
      *)                _stub_emit '{}' 404 ;;
    esac
  }
  export REPO_CAPTURE="$capture"
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_repo_upsert git@github.com:foo/bar.git main
  [ "$status" -eq 0 ]
  jq -e '.url == "git@github.com:foo/bar.git"' "$capture"
  jq -e '.last_branch == "main"'               "$capture"
}

@test "catalog_repo_list: extracts repo URLs in the server's (MRU) order" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/repos")
        _stub_emit '[{"url":"git@github.com:owner/myrepo.git"},{"url":"git@github.com:owner/other.git"}]' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_repo_list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "git@github.com:owner/myrepo.git" ]
  [ "${lines[1]}" = "git@github.com:owner/other.git" ]
}

@test "catalog_repo_last_branch: returns last_branch for a known URL, empty for unknown" {
  catalog_route() {
    # by-url carries the url as a query string; match on the path prefix.
    case "$1 ${2%%\?*}" in
      "GET /v1/repos/by-url")
        if [[ "$2" == *"myrepo"* ]]; then
          _stub_emit '{"url":"git@github.com:owner/myrepo.git","last_branch":"feature-x"}' 200
        else
          _stub_emit '{"error":{"code":"not_found"}}' 404
        fi ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_repo_last_branch git@github.com:owner/myrepo.git
  [ "$status" -eq 0 ]
  [ "$output" = "feature-x" ]
  run catalog_repo_last_branch git@github.com:nope/nope.git
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- defaults ---------------------------------------------------------------

@test "catalog_default: extracts a known key from GET /v1/defaults" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/defaults") _stub_emit '{"ide":"cursor","provider":"vossisrv"}' 200 ;;
      *)                  _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_default ide
  [ "$status" -eq 0 ]
  [ "$output" = "cursor" ]
  run catalog_default provider
  [ "$status" -eq 0 ]
  [ "$output" = "vossisrv" ]
}

@test "catalog_default: empty for an unknown key" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/defaults") _stub_emit '{"ide":"cursor","provider":"vossisrv"}' 200 ;;
      *)                  _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_default unknown_key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- client-local: devpod context + per-machine workspace.json --------------
# These read this machine's local files and never touch the service.

@test "catalog_devpod_context: falls back to default when devpod CLI absent" {
  source "$DVW_ROOT/lib/catalog.sh"
  PATH=/nonexistent:/usr/bin:/bin run catalog_devpod_context
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

@test "catalog_devpod_workspace_json_path: composes \$HOME/.devpod/contexts/<ctx>/workspaces/<id>/workspace.json" {
  source "$DVW_ROOT/lib/catalog.sh"
  PATH=/nonexistent:/usr/bin:/bin HOME="$TMPDIR" run catalog_devpod_workspace_json_path foo-id
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR/.devpod/contexts/default/workspaces/foo-id/workspace.json" ]
}

@test "catalog_workspace_set_devpod_state: PATCHes uid + devpod_state read from the local workspace.json" {
  local capture="$TMPDIR/patch-body.json"
  catalog_route() {
    case "$1 $2" in
      "PATCH /v1/workspaces/myrepo-feature-x")
        printf '%s' "$3" > "$PATCH_CAPTURE"; _stub_emit "$3" 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  export PATCH_CAPTURE="$capture"
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  # The client reads the LOCAL devpod workspace.json (top-level .uid) and snapshots
  # it into the PATCH payload; per PR #9 35e40dc we materialize a real local file.
  ws_path="$HOME/.devpod/contexts/default/workspaces/myrepo-feature-x/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  cat > "$ws_path" <<'JSON'
{"id":"myrepo-feature-x","uid":"default-my-abc12","provider":{"options":{"HOST":{"value":"vossisrv","userProvided":true}}}}
JSON
  PATH="$STUB_BIN:/usr/bin:/bin" run catalog_workspace_set_devpod_state myrepo-feature-x
  [ "$status" -eq 0 ]
  jq -e '.uid == "default-my-abc12"'                       "$capture"
  jq -e '.devpod_state.uid == "default-my-abc12"'          "$capture"
  jq -e '.devpod_state.provider.options.HOST.value == "vossisrv"' "$capture"
}

@test "catalog_workspace_set_devpod_state: errors when the local workspace.json is missing" {
  # No HTTP needed: the function bails before any request when the file is absent.
  source "$DVW_ROOT/lib/catalog.sh"
  PATH=/nonexistent:/usr/bin:/bin run catalog_workspace_set_devpod_state myrepo-feature-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "catalog_workspace_get_devpod_state: extracts the snapshot from the workspace response" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/myrepo-feature-x")
        _stub_emit '{"id":"myrepo-feature-x","devpod_state":{"workspace":{"uid":"default-my-abc12"}}}' 200 ;;
      *) _stub_emit '{"error":{"code":"not_found"}}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_get_devpod_state myrepo-feature-x
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.workspace.uid == "default-my-abc12"'
}

@test "catalog_workspace_get_devpod_state: errors when the workspace has no snapshot" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/myrepo-feature-x")
        _stub_emit '{"id":"myrepo-feature-x"}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_get_devpod_state myrepo-feature-x
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_get_uid: returns the workspace uid from the response; empty when unset" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/has-uid")
        _stub_emit '{"id":"has-uid","uid":"default-xy-99999"}' 200 ;;
      "GET /v1/workspaces/no-uid")
        _stub_emit '{"id":"no-uid"}' 200 ;;
      *) _stub_emit '{"error":{"code":"not_found"}}' 404 ;;
    esac
  }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_workspace_get_uid no-uid
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run catalog_workspace_get_uid has-uid
  [ "$status" -eq 0 ]
  [ "$output" = "default-xy-99999" ]
}
