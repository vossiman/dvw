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

@test "cache_stale: true (status 0) when cache missing" {
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}

@test "cache_stale: false (status 1) when cache is fresh" {
  _write_cache "$(date +%s)" 0
  run _dvw_update_cache_stale
  [ "$status" -ne 0 ]
}

@test "cache_stale: true (status 0) when cache older than TTL" {
  _write_cache 1 0           # epoch 1 = 1970, far older than any TTL
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}

@test "cache_stale: true when epoch is unparsable" {
  _write_cache nope 0
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}

@test "do_refresh: records the correct behind-count against the remote" {
  _advance_remote 2
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "2" ]
}

@test "do_refresh: records 0 when up to date" {
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "0" ]
}

@test "do_refresh: fail-open (exit 0, no cache) when remote is unreachable" {
  git -C "$DVW_ROOT" remote set-url origin "$TMP/does-not-exist.git"
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ ! -f "$DVW_STATE_DIR/update-check" ]
}

@test "refresh_if_stale: stale cache refreshes (sync mode) and records count" {
  export DVW_UPDATE_SYNC=1
  _advance_remote 3
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "3" ]
}

@test "refresh_if_stale: fresh cache does NOT refresh (count stays put)" {
  export DVW_UPDATE_SYNC=1
  _write_cache "$(date +%s)" 0     # fresh, says up-to-date
  _advance_remote 5                # remote moves ahead, but cache is fresh
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "0" ]   # unchanged — no fetch happened
}

@test "refresh_if_stale: fail-open (exit 0) when DVW_ROOT is not a git repo" {
  export DVW_ROOT="$TMP/notgit"; mkdir -p "$DVW_ROOT"
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
}
