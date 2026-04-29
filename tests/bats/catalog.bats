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
