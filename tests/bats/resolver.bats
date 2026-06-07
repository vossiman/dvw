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
