#!/usr/bin/env bats
#
# Client-side resolver logic in lib/connect.sh:
#   _dvw_pick_canonical_uid    — pure winner-selection over a probe blob
#   _dvw_uid_claimed_by_other  — jq over the full catalog (GET /v1/catalog)
#
# _dvw_pick_canonical_uid is pure (no I/O) and unchanged by the HTTP migration.
# _dvw_uid_claimed_by_other still reasons CLIENT-side over the whole catalog; it
# just sources the catalog from GET /v1/catalog now instead of a local file, so
# those tests serve the catalog body via the transport stub.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export DVW_CATALOG_HOST=stub
  export DVW_CATALOG_SOCK="$TMPDIR/not-a-socket.sock"
  load "lib/catalog-stub.bash"
}

teardown() { rm -rf "$TMPDIR"; }

# Load connect.sh with its deps and a stubbed ui layer.
_load_resolver() {
  ui_status_warn() { :; }
  ui_status_ok()   { :; }
  ui_info()        { :; }
  ui_error()       { echo "$*" >&2; }
  export -f ui_status_warn ui_status_ok ui_info ui_error
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
}

# Serve a fixed catalog body on GET /v1/catalog (everything else 404).
_serve_catalog() {
  export STUB_CATALOG_BODY="$1"
  catalog_route() {
    case "$1 $2" in
      "GET /v1/catalog") _stub_emit "$STUB_CATALOG_BODY" 200 ;;
      *)                 _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
}

@test "pick_canonical_uid: single candidate is chosen" {
  _load_resolver
  run _dvw_pick_canonical_uid "test-id" "$(printf 'default-de-aaaaa\t-1\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "default-de-aaaaa" ]
}

@test "pick_canonical_uid: empty probe yields no output, status 0 (cold)" {
  _load_resolver
  run _dvw_pick_canonical_uid "test-id" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pick_canonical_uid: among siblings, most-recently-active tmux holder wins" {
  _load_resolver
  probe=$(printf 'default-de-old\t100\ndefault-de-new\t900\n')
  run --separate-stderr _dvw_pick_canonical_uid "test-id" "$probe"
  [ "$status" -eq 0 ]
  [ "$output" = "default-de-new" ]
}

@test "pick_canonical_uid: >=2 candidates none with tmux is pathological (status 1)" {
  _load_resolver
  probe=$(printf 'default-de-a\t-1\ndefault-de-b\t-1\n')
  run _dvw_pick_canonical_uid "test-id" "$probe"
  [ "$status" -eq 1 ]
}

@test "pick_canonical_uid: stdout is uid-only on warning path with real ui_* (regression)" {
  source "$DVW_ROOT/lib/ui.sh"
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
  probe=$(printf 'default-de-old\t100\ndefault-de-new\t900\n')
  chosen=$(_dvw_pick_canonical_uid "test-id" "$probe" 2>/dev/null)
  [ "$chosen" = "default-de-new" ]
  # exactly one line on stdout — no diagnostic pollution
  [ "$(printf '%s' "$chosen" | wc -l)" -eq 0 ]
}

@test "uid_claimed_by_other: true when another workspace records the uid" {
  _serve_catalog '{ "version":1, "defaults":{}, "repos":[],
    "workspaces":[
      {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}},
      {"id":"beta","uid":"default-de-bbbbb","devpod_state":{"uid":"default-de-bbbbb"}}
    ] }'
  _load_resolver
  run _dvw_uid_claimed_by_other "alpha" "default-de-bbbbb"
  [ "$status" -eq 0 ]
}

@test "uid_claimed_by_other: false when only the same workspace records it" {
  _serve_catalog '{ "version":1, "defaults":{}, "repos":[],
    "workspaces":[
      {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
    ] }'
  _load_resolver
  run _dvw_uid_claimed_by_other "alpha" "default-de-aaaaa"
  [ "$status" -ne 0 ]
}

@test "uid_claimed_by_other: false when uid is unclaimed" {
  _serve_catalog '{ "version":1, "defaults":{}, "repos":[],
    "workspaces":[
      {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
    ] }'
  _load_resolver
  run _dvw_uid_claimed_by_other "alpha" "default-de-zzzzz"
  [ "$status" -ne 0 ]
}

@test "uid_claimed_by_other: false for empty uid" {
  _serve_catalog '{ "version":1, "defaults":{}, "repos":[],
    "workspaces":[
      {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
    ] }'
  _load_resolver
  run _dvw_uid_claimed_by_other "alpha" ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# HTTP resolver (lib/connect-resolver.sh) — stubbed _catalog_req routes
# ---------------------------------------------------------------------------

_load_http_resolver() {
  _load_resolver
  source "$DVW_ROOT/lib/connect-resolver.sh"
}

_ws_json() {
  local id="$1" uid="$2"
  mkdir -p "$HOME/.devpod/contexts/default/workspaces/$id"
  printf '{"id":"%s","uid":"%s"}\n' "$id" "$uid" \
    > "$HOME/.devpod/contexts/default/workspaces/$id/workspace.json"
}

@test "http resolve: cold — no container_id leaves local uid unchanged" {
  _ws_json coldws default-cold-aaaaa
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/coldws/container")
        _stub_emit '{"container_id":null,"devpod_uid":null,"ambiguous":false}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_resolve_canonical_container coldws
  [ "$status" -eq 0 ]
  jq -e '.uid == "default-cold-aaaaa"' \
    "$HOME/.devpod/contexts/default/workspaces/coldws/workspace.json" >/dev/null
}

@test "http resolve: align — rewrites local uid to service winner" {
  _ws_json alignws default-old-bbbbb
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/alignws/container")
        _stub_emit '{"container_id":"c123","devpod_uid":"default-new-ccccc","ambiguous":false}' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[],
          "workspaces":[{"id":"alignws","uid":"default-old-bbbbb"}] }' 200 ;;
      "PATCH /v1/workspaces/alignws")
        _stub_emit '{"ok":true}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_resolve_canonical_container alignws
  [ "$status" -eq 0 ]
  jq -e '.uid == "default-new-ccccc"' \
    "$HOME/.devpod/contexts/default/workspaces/alignws/workspace.json" >/dev/null
}

@test "http resolve: ambiguous — status 1, no uid rewrite" {
  _ws_json ambigws default-amb-ddddd
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/ambigws/container")
        _stub_emit '{"container_id":null,"devpod_uid":null,"ambiguous":true}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_resolve_canonical_container ambigws
  [ "$status" -eq 1 ]
  jq -e '.uid == "default-amb-ddddd"' \
    "$HOME/.devpod/contexts/default/workspaces/ambigws/workspace.json" >/dev/null
}

@test "http resolve: claimed — refuses align when another workspace owns uid" {
  _ws_json claimws default-claim-eeee
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/claimws/container")
        _stub_emit '{"container_id":"c999","devpod_uid":"default-taken-ffff","ambiguous":false}' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[],
          "workspaces":[
            {"id":"claimws","uid":"default-claim-eeee"},
            {"id":"other","uid":"default-taken-ffff","devpod_state":{"uid":"default-taken-ffff"}}
          ] }' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_resolve_canonical_container claimws
  [ "$status" -eq 1 ]
  jq -e '.uid == "default-claim-eeee"' \
    "$HOME/.devpod/contexts/default/workspaces/claimws/workspace.json" >/dev/null
}

@test "http resolve: unreachable — status 0, keeps current uid" {
  _ws_json unreach default-un-ggggg
  catalog_route() { exit 1; }   # transport failure (curl rc != 0)
  catalog_stub_install
  _load_http_resolver
  run _dvw_resolve_canonical_container unreach
  [ "$status" -eq 0 ]
  jq -e '.uid == "default-un-ggggg"' \
    "$HOME/.devpod/contexts/default/workspaces/unreach/workspace.json" >/dev/null
}

@test "http provider_has_container: true when container_id present" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/hasws/container")
        _stub_emit '{"container_id":"abc","devpod_uid":"default-has","ambiguous":false}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_provider_has_container hasws
  [ "$status" -eq 0 ]
}

@test "http provider_has_container: false when cold / unreachable" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/workspaces/nows/container")
        _stub_emit '{"container_id":null,"devpod_uid":null,"ambiguous":false}' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  run _dvw_provider_has_container nows
  [ "$status" -ne 0 ]
}

@test "http load_probe: maps liveness from status endpoint" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/containers/status")
        _stub_emit '[{"id":"a","liveness":"running"},{"id":"b","liveness":"stopped"}]' 200 ;;
      "GET /v1/containers/orphans")
        _stub_emit '[]' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[], "workspaces":[] }' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  unset DVW_PROBE_LOADED
  _dvw_load_probe
  [ "${DVW_PROBE_STATE[a]}" = "running" ]
  [ "${DVW_PROBE_STATE[b]}" = "stopped" ]
}

@test "http load_probe: records running_siblings when the server reports it" {
  catalog_route() {
    case "$1 $2" in
      "GET /v1/containers/status")
        _stub_emit '[{"id":"dup","liveness":"alive","running_siblings":2},{"id":"solo","liveness":"alive","running_siblings":1}]' 200 ;;
      "GET /v1/containers/orphans") _stub_emit '[]' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[], "workspaces":[] }' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  unset DVW_PROBE_LOADED
  _dvw_load_probe
  [ "${DVW_PROBE_SIBLINGS[dup]}" = "2" ]
  [ "${DVW_PROBE_SIBLINGS[solo]}" = "1" ]
}

@test "http load_probe: server without running_siblings still yields liveness" {
  # Regression: `\(.running_siblings // empty)` inside string interpolation
  # collapses the WHOLE row, silently dropping every status from an older
  # catalog service. Liveness must survive; siblings must stay unset.
  catalog_route() {
    case "$1 $2" in
      "GET /v1/containers/status")
        _stub_emit '[{"id":"a","liveness":"running"},{"id":"b","liveness":"stopped"}]' 200 ;;
      "GET /v1/containers/orphans") _stub_emit '[]' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[], "workspaces":[] }' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  unset DVW_PROBE_LOADED
  _dvw_load_probe
  [ "${DVW_PROBE_STATE[a]}" = "running" ]
  [ "${DVW_PROBE_STATE[b]}" = "stopped" ]
  [ -z "${DVW_PROBE_SIBLINGS[a]:-}" ]
}

@test "http load_probe: twin orphans sharing a devpod uid are both recorded" {
  # 2026-08-09: two racing `devpod up` runs created twin containers with the
  # SAME devpod uid. Keying orphan detail by uid collapsed them — `dvw doctor`
  # printed one container's name twice and hid the other entirely.
  catalog_route() {
    case "$1 $2" in
      "GET /v1/containers/status") _stub_emit '[]' 200 ;;
      "GET /v1/containers/orphans")
        _stub_emit '[
          {"devpod_uid":"default-de-54406","container_name":"twin_a","state":"running","mount_status":"alive","mount_source":"/src","workspace_id":"zombie"},
          {"devpod_uid":"default-de-54406","container_name":"twin_b","state":"running","mount_status":"alive","mount_source":"/src","workspace_id":"zombie"}
        ]' 200 ;;
      "GET /v1/catalog")
        _stub_emit '{ "version":1, "defaults":{}, "repos":[], "workspaces":[] }' 200 ;;
      *) _stub_emit '{}' 404 ;;
    esac
  }
  catalog_stub_install
  _load_http_resolver
  unset DVW_PROBE_LOADED
  _dvw_load_probe
  # One entry per CONTAINER, keyed by name — both twins visible.
  [ -n "${DVW_PROBE_ORPHAN_INFO[twin_a]:-}" ]
  [ -n "${DVW_PROBE_ORPHAN_INFO[twin_b]:-}" ]
  [ "$(grep -c . <<<"$DVW_PROBE_ORPHAN_NAMES")" = "2" ]
}
