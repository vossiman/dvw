#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export DVW_CATALOG="$TMPDIR/catalog.json"
}

teardown() { rm -rf "$TMPDIR"; }

# Load connect.sh with its deps. connect.sh uses ui_* and catalog_* functions;
# stub the ui layer and source the real catalog lib before sourcing connect.sh.
_load_resolver() {
  ui_status_warn() { :; }
  ui_status_ok()   { :; }
  ui_info()        { :; }
  ui_error()       { echo "$*" >&2; }
  export -f ui_status_warn ui_status_ok ui_info ui_error
  source "$DVW_ROOT/lib/catalog.sh"
  source "$DVW_ROOT/lib/connect.sh"
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
  _load_resolver
  cat > "$DVW_CATALOG" <<'JSON'
{ "version":1, "defaults":{}, "repos":[],
  "workspaces":[
    {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}},
    {"id":"beta","uid":"default-de-bbbbb","devpod_state":{"uid":"default-de-bbbbb"}}
  ] }
JSON
  run _dvw_uid_claimed_by_other "alpha" "default-de-bbbbb"
  [ "$status" -eq 0 ]
}

@test "uid_claimed_by_other: false when only the same workspace records it" {
  _load_resolver
  cat > "$DVW_CATALOG" <<'JSON'
{ "version":1, "defaults":{}, "repos":[],
  "workspaces":[
    {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
  ] }
JSON
  run _dvw_uid_claimed_by_other "alpha" "default-de-aaaaa"
  [ "$status" -ne 0 ]
}

@test "uid_claimed_by_other: false when uid is unclaimed" {
  _load_resolver
  cat > "$DVW_CATALOG" <<'JSON'
{ "version":1, "defaults":{}, "repos":[],
  "workspaces":[
    {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
  ] }
JSON
  run _dvw_uid_claimed_by_other "alpha" "default-de-zzzzz"
  [ "$status" -ne 0 ]
}

@test "uid_claimed_by_other: false for empty uid" {
  _load_resolver
  cat > "$DVW_CATALOG" <<'JSON'
{ "version":1, "defaults":{}, "repos":[],
  "workspaces":[
    {"id":"alpha","uid":"default-de-aaaaa","devpod_state":{"uid":"default-de-aaaaa"}}
  ] }
JSON
  run _dvw_uid_claimed_by_other "alpha" ""
  [ "$status" -ne 0 ]
}
