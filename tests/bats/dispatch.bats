#!/usr/bin/env bats
#
# Top-level argv dispatch in the `dvw` entry script. Regression coverage for
# the TUI double-prompt bug (2026-06-11): the TUI's connect modal hands off
# `dvw <id> --ssh|--cursor|--both` so the bash side skips its gum chooser,
# but the dispatcher dropped everything after $1, so cmd_connect never saw
# the flag and prompted again.
#
# The entry script is sourceable (main() runs only when executed directly),
# so we source it, stub the pre-dispatch machinery and the cmd_* layer, and
# assert on the argv that reaches cmd_connect.

setup() {
  # Plain source on purpose: dvw's own `set -euo pipefail` is harmless under
  # bats, but save/restore via `set +o` captured in a command substitution
  # restores errtrace OFF and silently disables bats' ERR-trap failure
  # detection (every assertion becomes a no-op). Don't "clean up" this line.
  source "$DVW_ROOT/dvw"

  # Pre-dispatch machinery: no network, no spinner, no update nudge.
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  # Record the argv cmd_connect receives, one arg per line.
  cmd_connect() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/connect-argv"; }
}

@test "dispatch: dvw <id> reaches cmd_connect with just the id" {
  run main myws
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/connect-argv")" = "myws" ]
}

@test "dispatch: dvw <id> --ssh forwards the mode flag to cmd_connect" {
  run main myws --ssh
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/connect-argv")" = "myws
--ssh" ]
}

@test "dispatch: dvw <id> --cursor forwards the mode flag to cmd_connect" {
  run main myws --cursor
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/connect-argv")" = "myws
--cursor" ]
}

@test "dispatch: dvw <id> --both forwards the mode flag to cmd_connect" {
  run main myws --both
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/connect-argv")" = "myws
--both" ]
}

@test "dispatch: --dry-run is consumed and not forwarded to cmd_connect" {
  run main myws --ssh --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/connect-argv")" = "myws
--ssh" ]
}
