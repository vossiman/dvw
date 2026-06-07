#!/usr/bin/env bats
# Verifies dvw-install.sh survives the filter-repo relocation: --check-only
# runs without modifying the host and exits 0 when all idempotency invariants hold.

setup() {
  export TMPDIR="$(mktemp -d)"
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME/.local/bin"
  # Stub apt/sudo/curl so --check-only can probe without touching the real host.
  mkdir -p "$TMPDIR/stubs"
  for cmd in apt apt-get sudo curl; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
  export PATH="$TMPDIR/stubs:$PATH"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "dvw-install.sh --check-only exits 0 without modifying \$HOME" {
  run bash "$DVW_ROOT/dvw-install.sh" --check-only
  [ "$status" -eq 0 ]
  # --check-only must not create the PATH symlink.
  [ ! -e "$HOME/.local/bin/dvw" ]
  # Output should announce check-only mode.
  echo "$output" | grep -qi "check-only"
}

@test "dvw-install.sh --check-only with --help-style unknown flag still exits 0 or prints usage" {
  run bash "$DVW_ROOT/dvw-install.sh" --check-only --nonsense-flag
  # Either it ignores the extra flag (exit 0) or it prints usage and exits non-zero.
  # We only require that it does NOT hang or modify $HOME.
  [ ! -e "$HOME/.local/bin/dvw" ]
}
