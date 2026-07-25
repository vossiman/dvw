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

@test "maybe_nudge: prints the CTA line when behind and subcommand != update" {
  _write_cache 123 2
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind main — run: dvw update"* ]]
}

@test "maybe_nudge: silent for the update subcommand even when behind" {
  _write_cache 123 2
  run dvw_update_maybe_nudge update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "maybe_nudge: silent when up to date (count 0)" {
  _write_cache 123 0
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "maybe_nudge: silent when unknown (no cache)" {
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- superproject mode -------------------------------------------------------
# When dvw is pinned as a submodule, the staleness that matters is the PARENT's
# (its main is what `dvw update` follows), not dvw's own.

# Build: bare parent remote + parent clone with $REMOTE added as submodule "sub".
# Leaves PARENT/SUPER_REMOTE set and DVW_ROOT pointing at the submodule checkout.
_make_super() {
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  SUPER_REMOTE="$TMP/super.git"; git init -q --bare -b main "$SUPER_REMOTE"
  PARENT="$TMP/super"; git clone -q "$SUPER_REMOTE" "$PARENT"
  git -C "$PARENT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m super
  git -C "$PARENT" -c user.email=t@t -c user.name=t \
      -c protocol.file.allow=always submodule add -q -b main "$REMOTE" sub
  git -C "$PARENT" -c user.email=t@t -c user.name=t commit -q -m "add sub"
  git -C "$PARENT" push -q origin main
  export DVW_ROOT="$PARENT/sub"
}

# Advance the parent's remote main by N empty commits (throwaway clone).
_advance_super_remote() {
  local n=$1 w2="$TMP/sw2"
  rm -rf "$w2"; git clone -q "$SUPER_REMOTE" "$w2"
  local i; for ((i=0;i<n;i++)); do
    git -C "$w2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "s$i"
  done
  git -C "$w2" push -q origin main
}

@test "superproject_root: empty for a standalone checkout" {
  run dvw_superproject_root
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "superproject_root: the parent working tree for a submodule checkout" {
  _make_super
  run dvw_superproject_root
  [ "$output" = "$PARENT" ]
}

@test "target_repo/name: dvw checkout when standalone" {
  run dvw_update_target_repo
  [ "$output" = "$WORK" ]
  run dvw_update_target_name
  [ "$output" = "dvw" ]
}

@test "target_repo/name: the parent when a submodule checkout" {
  _make_super
  run dvw_update_target_repo
  [ "$output" = "$PARENT" ]
  run dvw_update_target_name
  [ "$output" = "super" ]
}

@test "refresh: counts the PARENT's behind-count in superproject mode" {
  _make_super
  _advance_super_remote 3
  DVW_UPDATE_SYNC=1 dvw_update_refresh_if_stale
  [ "$(dvw_update_behind_count)" = "3" ]
}

@test "refresh: parent stale but dvw pin current still reports behind" {
  # The exact loop the old CTA caused: dvw's own main may be ahead of the pin
  # forever. What we report is the parent's, which `dvw update` can resolve.
  _make_super
  _advance_remote 5          # dvw's own main moves; the pin does not
  _advance_super_remote 1
  DVW_UPDATE_SYNC=1 dvw_update_refresh_if_stale
  [ "$(dvw_update_behind_count)" = "1" ]
}

@test "nudge: superproject mode names the parent and says run: dvw update" {
  _make_super
  _write_cache "$(date +%s)" 2
  run dvw_update_maybe_nudge status
  [[ "$output" == *"super behind main"* ]]
  [[ "$output" == *"run: dvw update"* ]]
  [[ "$output" != *"bump parent"* ]]
}
