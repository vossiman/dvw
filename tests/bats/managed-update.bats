#!/usr/bin/env bats

setup() {
  : "${DVW_ROOT:?}"
  REAL_ROOT="$DVW_ROOT"
  export HOME="$BATS_TEST_TMPDIR/home"
  export AICODING_STATE_DIR="$BATS_TEST_TMPDIR/state/aicoding"
  MANAGED_ROOT="$BATS_TEST_TMPDIR/managed"
  mkdir -p "$HOME/bin" "$AICODING_STATE_DIR" "$MANAGED_ROOT/lib"
  cp "$REAL_ROOT/lib/version.sh" "$MANAGED_ROOT/lib/version.sh"
  printf '%s\n' "1111111111111111111111111111111111111111" > "$MANAGED_ROOT/.aicoding-version"
  export DVW_ROOT="$MANAGED_ROOT"
  source "$REAL_ROOT/lib/version.sh"
  source "$REAL_ROOT/lib/update-check.sh"
  source "$REAL_ROOT/lib/commands.sh"
  ui_info() { printf 'INFO: %s\n' "$*"; }
  ui_error() { printf 'ERROR: %s\n' "$*" >&2; }
}

write_result() {
  local state="$1" reason="$2"
  jq -n --arg state "$state" --arg reason "$reason" '{
    schema:1,
    attempted_at:"2026-09-11T10:00:00Z",
    components:{dvw:{
      attempted_at:"2026-09-11T10:00:00Z",
      successful_version:"1111111111111111111111111111111111111111",
      target_version:"2222222222222222222222222222222222222222",
      state:$state,
      reason:$reason,
      succeeded_at:"2026-09-11T09:00:00Z"
    }}
  }' > "$AICODING_STATE_DIR/update-results.json"
}

@test "managed update invokes the common runner with closed stdin and never calls git" {
  cat > "$HOME/bin/aicoding-auto-update" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$AUTO_UPDATE_CALL"
if read -r value; then
  echo "stdin was open: $value" >&2
  exit 8
fi
EOF
  cat > "$HOME/bin/git" <<'EOF'
#!/bin/sh
echo "git SHOULD NOT RUN" >&2
exit 99
EOF
  chmod +x "$HOME/bin/aicoding-auto-update" "$HOME/bin/git"
  export AUTO_UPDATE_CALL="$BATS_TEST_TMPDIR/auto-update-call"

  PATH="$HOME/bin:$PATH" run cmd_update <<<"unexpected input"
  [ "$status" -eq 0 ]
  [ "$(cat "$AUTO_UPDATE_CALL")" = "--once" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "installed managed dvw update bypasses catalog SSH WSL and devpod preflights" {
  cp "$REAL_ROOT/dvw" "$MANAGED_ROOT/dvw"
  cp -a "$REAL_ROOT/lib/." "$MANAGED_ROOT/lib/"
  chmod +x "$MANAGED_ROOT/dvw"
  cat > "$HOME/bin/aicoding-auto-update" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$AUTO_UPDATE_CALL"
EOF
  local command_name
  for command_name in ssh wslpath cmd.exe devpod git; do
    cat > "$HOME/bin/$command_name" <<'EOF'
#!/bin/sh
printf '%s\n' "$0" >> "$PREFLIGHT_CALLS"
exit 97
EOF
    chmod +x "$HOME/bin/$command_name"
  done
  chmod +x "$HOME/bin/aicoding-auto-update"
  export AUTO_UPDATE_CALL="$BATS_TEST_TMPDIR/auto-update-entrypoint-call"
  export PREFLIGHT_CALLS="$BATS_TEST_TMPDIR/preflight-calls"

  PATH="$HOME/bin:/usr/bin:/bin" WSL_DISTRO_NAME=fixture \
    run "$MANAGED_ROOT/dvw" update <<<"unexpected input"
  [ "$status" -eq 0 ]
  [ "$(cat "$AUTO_UPDATE_CALL")" = "--once" ]
  [ ! -e "$PREFLIGHT_CALLS" ]
}

@test "managed update fails clearly when the common runner is unavailable" {
  command() {
    [[ "$1" == -v && "$2" == aicoding-auto-update ]] && return 1
    builtin command "$@"
  }
  run cmd_update
  [ "$status" -ne 0 ]
  [[ "$output" == *"aicoding-auto-update is unavailable"* ]]
}

@test "managed refresh never calls git or writes the legacy cache" {
  git() { touch "$BATS_TEST_TMPDIR/git-ran"; return 99; }
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/git-ran" ]
  [ ! -e "$HOME/.local/state/dvw/update-check" ]
}

@test "managed result exposes the common runner status" {
  write_result blocked "manual rebuild required"
  run dvw_managed_update_result
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = blocked ]
  [ "$(jq -r '.target_version' <<<"$output")" = "2222222222222222222222222222222222222222" ]
  [ "$(jq -r '.reason' <<<"$output")" = "manual rebuild required" ]
}

@test "managed failed result produces a startup nudge without Git" {
  write_result failed "staging failed"
  git() { echo "git SHOULD NOT RUN"; return 99; }
  run dvw_update_maybe_nudge status
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed update failed: staging failed"* ]]
  [[ "$output" == *"retry automatically"* ]]
  [[ "$output" != *"run: dvw update"* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "managed result preserves the reason when target version is null" {
  write_result failed "selection unavailable"
  jq '.components.dvw.target_version = null' \
    "$AICODING_STATE_DIR/update-results.json" > "$BATS_TEST_TMPDIR/result"
  mv "$BATS_TEST_TMPDIR/result" "$AICODING_STATE_DIR/update-results.json"

  run dvw_update_maybe_nudge status
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed update failed: selection unavailable"* ]]
}

@test "managed current result is silent" {
  write_result current "already selected"
  run dvw_update_maybe_nudge status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
