#!/usr/bin/env bats

setup() {
  : "${DVW_ROOT_TEST:?}"
  TMP=$(mktemp -d); export HOME="$TMP"
  export DVW_STATE_DIR="$TMP/state/dvw"
  source "$DVW_ROOT_TEST/lib/version.sh"
  REPO="$TMP/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
}
teardown() { rm -rf "$TMP"; }

@test "marker path honors DVW_STATE_DIR override" {
  [ "$(dvw_version_marker_path)" = "$DVW_STATE_DIR/version" ]
}

@test "write records the repo HEAD; read returns it" {
  dvw_write_version_marker "$REPO"
  local head; head=$(git -C "$REPO" rev-parse HEAD)
  [ "$(cat "$DVW_STATE_DIR/version")" = "$head" ]
  [ "$(dvw_installed_version)" = "$head" ]
}

@test "installed_version is empty when no marker exists" {
  [ -z "$(dvw_installed_version)" ]
}
