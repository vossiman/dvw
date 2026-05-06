#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export DVW_CATALOG="$TMPDIR/catalog.json"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "harness smoke: bats can run a trivial test" {
  [ 1 = 1 ]
}

@test "catalog_path: respects DVW_CATALOG env" {
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_path
  [ "$status" -eq 0 ]
  [ "$output" = "$DVW_CATALOG" ]
}

@test "catalog_path: defaults to ~/Dropbox-remote/dvw/catalog.json when DVW_CATALOG unset" {
  unset DVW_CATALOG
  source "$DVW_ROOT/lib/catalog.sh"
  run catalog_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Dropbox-remote/dvw/catalog.json" ]
}

@test "catalog_init_if_missing: creates fresh catalog when absent" {
  source "$DVW_ROOT/lib/catalog.sh"
  [ ! -f "$DVW_CATALOG" ]
  run catalog_init_if_missing
  [ "$status" -eq 0 ]
  [ -f "$DVW_CATALOG" ]
  jq -e '.version == 1' "$DVW_CATALOG"
  jq -e '.workspaces | length == 0' "$DVW_CATALOG"
  jq -e '.repos | length == 0' "$DVW_CATALOG"
  jq -e '.defaults.ide == "cursor"' "$DVW_CATALOG"
}

@test "catalog_init_if_missing: leaves existing catalog untouched" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  before_hash=$(sha256sum "$DVW_CATALOG")
  run catalog_init_if_missing
  [ "$status" -eq 0 ]
  after_hash=$(sha256sum "$DVW_CATALOG")
  [ "$before_hash" = "$after_hash" ]
}

@test "catalog_init_if_missing: fails loudly when parent dir is unwritable" {
  source "$DVW_ROOT/lib/catalog.sh"
  export DVW_CATALOG=/nonexistent-path-xyz/dvw/catalog.json
  run catalog_init_if_missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"catalog unreachable"* ]] || [[ "$output" == *"rclone mount"* ]]
}

@test "catalog_read: returns valid catalog content" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_read
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version": 1'* ]]
}

@test "catalog_read: fails loudly on malformed JSON" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/malformed-catalog.json" "$DVW_CATALOG"
  run catalog_read
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]] || [[ "$output" == *"parse"* ]]
}

@test "catalog_read: fails loudly on future schema version" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/future-version-catalog.json" "$DVW_CATALOG"
  run catalog_read
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer"* ]] || [[ "$output" == *"version"* ]]
}

@test "catalog_read: fails when catalog file missing (does NOT auto-create)" {
  source "$DVW_ROOT/lib/catalog.sh"
  [ ! -f "$DVW_CATALOG" ]
  run catalog_read
  [ "$status" -ne 0 ]
}

@test "catalog_write: writes JSON atomically (no .tmp left behind)" {
  source "$DVW_ROOT/lib/catalog.sh"
  catalog_init_if_missing
  echo '{"version":1,"defaults":{"ide":"cursor","provider":"vossisrv"},"workspaces":[{"id":"x","repo":"r","branch":"b","ide":"cursor","provider":"vossisrv","created_at":"2026-04-29T00:00:00Z","last_used_at":"2026-04-29T00:00:00Z","created_on":"test"}],"repos":[]}' \
    | catalog_write
  [ -f "$DVW_CATALOG" ]
  [ ! -f "$DVW_CATALOG.tmp" ]
  jq -e '.workspaces[0].id == "x"' "$DVW_CATALOG"
}

@test "catalog_write: refuses to write malformed JSON" {
  source "$DVW_ROOT/lib/catalog.sh"
  catalog_init_if_missing
  before=$(cat "$DVW_CATALOG")
  run bash -c 'source "$DVW_ROOT/lib/catalog.sh"; echo "{ bad json" | catalog_write'
  [ "$status" -ne 0 ]
  after=$(cat "$DVW_CATALOG")
  [ "$before" = "$after" ]
}

@test "catalog_workspace_ids: lists IDs in last-used-desc order" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_ids
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "myrepo-feature-x" ]
  [ "${lines[1]}" = "other-main" ]
}

@test "catalog_workspace_ids: empty list when no workspaces" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/empty-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_ids
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "catalog_workspace_get: returns workspace JSON for known ID" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_get myrepo-feature-x
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "myrepo-feature-x"'
  echo "$output" | jq -e '.ide == "cursor"'
}

@test "catalog_workspace_get: exits non-zero for unknown ID" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_get nonexistent
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_add: appends a new workspace entry" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/empty-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_add new-ws \
    git@github.com:foo/bar.git main cursor vossisrv testhost
  [ "$status" -eq 0 ]
  jq -e '.workspaces | length == 1' "$DVW_CATALOG"
  jq -e '.workspaces[0].id == "new-ws"' "$DVW_CATALOG"
  jq -e '.workspaces[0].ide == "cursor"' "$DVW_CATALOG"
  jq -e '.workspaces[0].created_on == "testhost"' "$DVW_CATALOG"
  jq -e '.workspaces[0].created_at | test("[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$DVW_CATALOG"
}

@test "catalog_workspace_add: rejects duplicate ID" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_add myrepo-feature-x \
    git@github.com:foo/bar.git main cursor vossisrv testhost
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_remove: removes by ID" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_remove myrepo-feature-x
  [ "$status" -eq 0 ]
  jq -e '.workspaces | length == 1' "$DVW_CATALOG"
  jq -e '.workspaces[0].id == "other-main"' "$DVW_CATALOG"
}

@test "catalog_workspace_remove: no-op on unknown ID returns success" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_remove nonexistent
  [ "$status" -eq 0 ]
  jq -e '.workspaces | length == 2' "$DVW_CATALOG"
}

@test "catalog_workspace_touch: bumps last_used_at" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  before=$(jq -r '.workspaces[] | select(.id=="myrepo-feature-x") | .last_used_at' "$DVW_CATALOG")
  sleep 1
  run catalog_workspace_touch myrepo-feature-x
  [ "$status" -eq 0 ]
  after=$(jq -r '.workspaces[] | select(.id=="myrepo-feature-x") | .last_used_at' "$DVW_CATALOG")
  [ "$before" != "$after" ]
}

@test "catalog_repo_upsert: appends a new repo entry" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/empty-catalog.json" "$DVW_CATALOG"
  run catalog_repo_upsert git@github.com:foo/bar.git main
  [ "$status" -eq 0 ]
  jq -e '.repos | length == 1' "$DVW_CATALOG"
  jq -e '.repos[0].url == "git@github.com:foo/bar.git"' "$DVW_CATALOG"
  jq -e '.repos[0].last_branch == "main"' "$DVW_CATALOG"
}

@test "catalog_repo_upsert: updates last_branch and last_used_at on existing repo" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  before_used=$(jq -r '.repos[] | select(.url=="git@github.com:owner/myrepo.git") | .last_used_at' "$DVW_CATALOG")
  sleep 1
  run catalog_repo_upsert git@github.com:owner/myrepo.git different-branch
  [ "$status" -eq 0 ]
  jq -e '.repos | length == 2' "$DVW_CATALOG"
  jq -e '.repos[] | select(.url=="git@github.com:owner/myrepo.git") | .last_branch == "different-branch"' "$DVW_CATALOG"
  after_used=$(jq -r '.repos[] | select(.url=="git@github.com:owner/myrepo.git") | .last_used_at' "$DVW_CATALOG")
  [ "$before_used" != "$after_used" ]
}

@test "catalog_repo_list: returns URLs in MRU order" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_repo_list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "git@github.com:owner/myrepo.git" ]
  [ "${lines[1]}" = "git@github.com:owner/other.git" ]
}

@test "catalog_repo_last_branch: returns last branch for known URL, empty for unknown" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_repo_last_branch git@github.com:owner/myrepo.git
  [ "$status" -eq 0 ]
  [ "$output" = "feature-x" ]
  run catalog_repo_last_branch git@github.com:nope/nope.git
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "catalog_default: returns default value for known key" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_default ide
  [ "$status" -eq 0 ]
  [ "$output" = "cursor" ]
  run catalog_default provider
  [ "$status" -eq 0 ]
  [ "$output" = "vossisrv" ]
}

@test "catalog_default: empty for unknown key" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_default unknown_key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- multi-machine sync helpers ---------------------------------------------

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

@test "catalog_workspace_set_devpod_state: writes uid + devpod_state from local workspace.json" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  export HOME="$TMPDIR"
  PATH=/nonexistent:/usr/bin:/bin
  ws_path="$HOME/.devpod/contexts/default/workspaces/myrepo-feature-x/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  cat > "$ws_path" <<'JSON'
{"id":"myrepo-feature-x","workspace":{"uid":"default-my-abc12","provider":{"options":{"HOST":{"value":"vossisrv","userProvided":true}}}}}
JSON
  PATH=/nonexistent:/usr/bin:/bin run catalog_workspace_set_devpod_state myrepo-feature-x
  [ "$status" -eq 0 ]
  jq -e '.workspaces[] | select(.id=="myrepo-feature-x") | .uid == "default-my-abc12"' "$DVW_CATALOG"
  jq -e '.workspaces[] | select(.id=="myrepo-feature-x") | .devpod_state.workspace.uid == "default-my-abc12"' "$DVW_CATALOG"
  jq -e '.workspaces[] | select(.id=="myrepo-feature-x") | .devpod_state.workspace.provider.options.HOST.value == "vossisrv"' "$DVW_CATALOG"
}

@test "catalog_workspace_set_devpod_state: errors when local workspace.json missing" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  export HOME="$TMPDIR"
  PATH=/nonexistent:/usr/bin:/bin run catalog_workspace_set_devpod_state myrepo-feature-x
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_get_devpod_state: round-trips snapshot" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  export HOME="$TMPDIR"
  PATH=/nonexistent:/usr/bin:/bin
  ws_path="$HOME/.devpod/contexts/default/workspaces/myrepo-feature-x/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  cat > "$ws_path" <<'JSON'
{"workspace":{"uid":"default-my-abc12","provider":{"options":{"HOST":{"value":"vossisrv"}}}},"id":"myrepo-feature-x"}
JSON
  PATH=/nonexistent:/usr/bin:/bin catalog_workspace_set_devpod_state myrepo-feature-x
  run catalog_workspace_get_devpod_state myrepo-feature-x
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.workspace.uid == "default-my-abc12"'
}

@test "catalog_workspace_get_devpod_state: errors when no snapshot" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_get_devpod_state myrepo-feature-x
  [ "$status" -ne 0 ]
}

@test "catalog_workspace_get_uid: returns top-level uid; empty when unset" {
  source "$DVW_ROOT/lib/catalog.sh"
  cp "$DVW_ROOT/tests/bats/fixtures/valid-catalog.json" "$DVW_CATALOG"
  run catalog_workspace_get_uid myrepo-feature-x
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  export HOME="$TMPDIR"
  ws_path="$HOME/.devpod/contexts/default/workspaces/myrepo-feature-x/workspace.json"
  mkdir -p "$(dirname "$ws_path")"
  echo '{"workspace":{"uid":"default-xy-99999"}}' > "$ws_path"
  PATH=/nonexistent:/usr/bin:/bin catalog_workspace_set_devpod_state myrepo-feature-x
  run catalog_workspace_get_uid myrepo-feature-x
  [ "$status" -eq 0 ]
  [ "$output" = "default-xy-99999" ]
}
