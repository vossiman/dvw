#!/usr/bin/env bats
#
# Bare `dvw` (no subcommand) — TUI-or-error. The gum top menu is gone
# (2026-08-10): when the TUI can't run, bare `dvw` prints an error + the
# subcommand list and exits 1, instead of falling back to a menu.
#
# Harness follows dispatch.bats: source the entry script (main() only
# auto-runs when executed directly, so sourcing + calling `main` lets us
# stub the pre-dispatch machinery) and tui-launch.bats's socket-stubbing
# convention (bind a real AF_UNIX socket so `_dvw_tui_ensure_socket`'s
# `[[ -S "$sock" ]]` short-circuit succeeds without touching ssh).

setup() {
  # Plain source, same rationale as dispatch.bats: `set +o` save/restore
  # around a sourced `set -euo pipefail` script disables bats' ERR-trap
  # failure detection.
  source "$DVW_ROOT/dvw"

  # Pre-dispatch machinery: no network, no spinner, no update nudge.
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
}

@test "bare dvw with TUI unavailable errors with subcommand list, exit 1" {
  export DVW_NO_TUI=1
  run main
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'TUI is unavailable'
  echo "$output" | grep -q 'subcommands:'
}

@test "bare dvw runs the TUI when available" {
  export DVW_TUI_FORCE=1

  # _dvw_tui_ensure_socket (lib/tui-launch.sh): a real AF_UNIX socket at
  # DVW_CATALOG_SOCK is returned immediately, same as
  # tui-launch.bats's "local service socket wins" test — no ssh involved.
  local sock="$BATS_TEST_TMPDIR/catalog.sock"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$sock"
  export DVW_CATALOG_SOCK="$sock"

  # Stub uv to record it ran and exit 0, standing in for the real `uv run
  # --project tui dvw-tui` launch.
  printf '#!/bin/sh\necho "UV-TUI $*" > "%s/uv-ran"\nexit 0\n' "$BATS_TEST_TMPDIR" \
    > "$STUB_DIR/uv"
  chmod +x "$STUB_DIR/uv"
  export PATH="$STUB_DIR:$PATH"

  run main
  [ "$status" -eq 0 ]
  grep -q 'UV-TUI' "$BATS_TEST_TMPDIR/uv-ran"
}
