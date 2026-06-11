#!/usr/bin/env bats
# cmd_doctor reports uv presence (warn-only: TUI degrades to menu without it).

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  export DVW_ROOT
  source "$DVW_ROOT/lib/ui.sh"
  source "$DVW_ROOT/lib/commands.sh"
}

@test "doctor uv check: present -> OK line" {
  STUB="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB"
  printf '#!/bin/sh\necho "uv 0.7.0"\n' > "$STUB/uv"; chmod +x "$STUB/uv"
  PATH="$STUB:$PATH" run _dvw_doctor_check_uv
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]] && [[ "$output" == *"uv"* ]]
}

@test "doctor uv check: missing -> WARN with install hint" {
  STUB="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB"
  for t in printf grep sed; do ln -s "$(command -v $t)" "$STUB/$t" 2>/dev/null || true; done
  PATH="$STUB" run _dvw_doctor_check_uv
  [ "$status" -eq 1 ]
  [[ "$output" == *"[WARN]"* ]] && [[ "$output" == *"gum menu"* ]]
}
