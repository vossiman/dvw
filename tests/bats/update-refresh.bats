#!/usr/bin/env bats
#
# Regression (2026-06-16): `dvw update` brought HEAD to origin/main and rewrote
# the version marker, but never refreshed the "behind main" cache that
# `dvw doctor` / the startup nudge read. The throttled background refresher only
# re-checks past the 6h TTL, so the pre-update count survived and doctor kept
# reporting "N commit(s) behind main" right after a successful update.
#
# cmd_update now calls _dvw_update_do_refresh inline after the pull. These tests
# pin that: local fixture remote (no network), stubbed installer (no apt/sudo),
# synchronous refresh (no backgrounded process, no zombies).

setup() {
  : "${DVW_ROOT:?}"
  REAL_ROOT="$DVW_ROOT"                       # capture before repointing
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

  # The checkout cmd_update operates on needs the libs it sources at runtime
  # plus a no-op installer (the real one runs apt/sudo/network — never in tests).
  mkdir -p "$WORK/lib"
  cp "$REAL_ROOT/lib/version.sh" "$WORK/lib/version.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/dvw-install.sh"
  chmod +x "$WORK/dvw-install.sh"

  # Source the code under test; ui_* and the refresher come from the real repo.
  source "$REAL_ROOT/lib/update-check.sh"
  source "$REAL_ROOT/lib/commands.sh"
  ui_info() { :; }
  ui_error() { printf 'ERROR: %s\n' "$*" >&2; }

  export DVW_ROOT="$WORK"                     # cmd_update operates on the fixture
}
teardown() { rm -rf "$TMP"; }

_write_cache() { mkdir -p "$DVW_STATE_DIR"; printf '%s\n%s\n' "$1" "$2" > "$DVW_STATE_DIR/update-check"; }

@test "cmd_update: refreshes a fresh-but-stale behind-count to 0 (the bug)" {
  # Cache is recent (within TTL) but holds a pre-update count. The background
  # refresher would skip it as 'fresh'; cmd_update must correct it anyway.
  _write_cache "$(date +%s)" 2
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(sed -n '2p' "$DVW_STATE_DIR/update-check")" = "0" ]
}

@test "cmd_update: no leftover background jobs (synchronous refresh)" {
  _write_cache "$(date +%s)" 2
  run cmd_update
  [ "$status" -eq 0 ]
  # The refresh runs inline; nothing should be backgrounded by cmd_update.
  run jobs -p
  [ -z "$output" ]
}
