#!/usr/bin/env bats
# _dvw_push_pick_fresh: newest Termius-style upload (UUIDv4.ext) in /tmp,
# filtered by owner/mtime/size. Pure logic — everything under a private TMPDIR.

bats_require_minimum_version 1.5.0

UUID_A="570d7e98-a20a-4e6a-ab30-c4b3400ae490"
UUID_B="99999999-1111-4222-8333-444444444444"

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
}

teardown() { rm -rf "$TMPDIR"; }

_load() {
  ui_error() { :; }; ui_info() { :; }
  source "$DVW_ROOT/lib/push.sh"
}

@test "picks the newest UUID-named file" {
  _load
  printf x > "$TMPDIR/$UUID_A.png"
  printf x > "$TMPDIR/$UUID_B.jpg"
  touch -d '5 minutes ago' "$TMPDIR/$UUID_A.png"
  run _dvw_push_pick_fresh
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR/$UUID_B.jpg" ]
}

@test "ignores non-UUID names" {
  _load
  printf x > "$TMPDIR/notes.png"
  printf x > "$TMPDIR/dvw-push-test"
  run _dvw_push_pick_fresh
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ignores files older than the freshness window" {
  _load
  printf x > "$TMPDIR/$UUID_A.png"
  touch -d '11 minutes ago' "$TMPDIR/$UUID_A.png"
  run _dvw_push_pick_fresh
  [ "$status" -eq 1 ]
}

@test "freshness window is configurable" {
  _load
  printf x > "$TMPDIR/$UUID_A.png"
  touch -d '11 minutes ago' "$TMPDIR/$UUID_A.png"
  DVW_PUSH_FRESH_MINUTES=30 run _dvw_push_pick_fresh
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR/$UUID_A.png" ]
}

@test "ignores files over the size cap" {
  _load
  truncate -s 2M "$TMPDIR/$UUID_A.png"
  DVW_PUSH_MAX_SIZE_MB=1 run _dvw_push_pick_fresh
  [ "$status" -eq 1 ]
}

@test "ignores UUID-named directories" {
  _load
  mkdir "$TMPDIR/$UUID_A.d"
  run _dvw_push_pick_fresh
  [ "$status" -eq 1 ]
}

@test "check_size passes small files and fails oversized ones" {
  _load
  printf x > "$TMPDIR/small"
  truncate -s 2M "$TMPDIR/big"
  run _dvw_push_check_size "$TMPDIR/small"
  [ "$status" -eq 0 ]
  DVW_PUSH_MAX_SIZE_MB=1 run _dvw_push_check_size "$TMPDIR/big"
  [ "$status" -eq 1 ]
}
