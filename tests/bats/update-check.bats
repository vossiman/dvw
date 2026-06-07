#!/usr/bin/env bats
#
# dvw update notifier (spec 2026-06-07): is the checkout behind origin/main?
# Throttled, fail-open, never blocks. Tests use a local fixture remote (no net).

setup() {
  : "${DVW_ROOT:?}"
  LIB="$DVW_ROOT/lib/update-check.sh"        # capture before we repoint DVW_ROOT
  TMP=$(mktemp -d); export HOME="$TMP"
  export DVW_STATE_DIR="$TMP/state"
  export DVW_UPDATE_TTL=21600
  unset DVW_UPDATE_SYNC

  # Fixture: a bare "remote" + a working clone that acts as the dvw checkout.
  REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
  WORK="$TMP/work"; git clone -q "$REMOTE" "$WORK"
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WORK" push -q origin HEAD:main
  git -C "$WORK" branch -q -M main
  git -C "$WORK" branch -q --set-upstream-to=origin/main main

  source "$LIB"
  export DVW_ROOT="$WORK"                     # functions operate on the fixture
}
teardown() { rm -rf "$TMP"; }

# Advance the remote main by N empty commits (via a throwaway second clone).
_advance_remote() {
  local n=$1 w2="$TMP/w2"
  rm -rf "$w2"; git clone -q "$REMOTE" "$w2"
  git -C "$w2" -c user.email=t@t -c user.name=t checkout -q main
  local i; for ((i=0;i<n;i++)); do
    git -C "$w2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "c$i"
  done
  git -C "$w2" push -q origin main
}

_write_cache() { mkdir -p "$DVW_STATE_DIR"; printf '%s\n%s\n' "$1" "$2" > "$DVW_STATE_DIR/update-check"; }

@test "behind_count: empty (unknown) when no cache" {
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "behind_count: echoes the cached count" {
  _write_cache 123 3
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "behind_count: empty when count is unparsable" {
  _write_cache 123 xyz
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
