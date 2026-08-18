#!/usr/bin/env bats
# cmd_push: argv contract, scp invocation shape, output contract (bare
# container path as final stdout line), size/existence errors, --clipboard
# helper selection, --dry-run. scp/clipboard tools stubbed on PATH;
# resolve-target and alias registration stubbed at the function boundary.

bats_require_minimum_version 1.5.0

UUID_A="570d7e98-a20a-4e6a-ab30-c4b3400ae490"

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  SCP_ARGS="$TMPDIR/scp-args"; : > "$SCP_ARGS"
  export SCP_ARGS
  cat > "$STUB_BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SCP_ARGS"
exit "${SCP_STUB_RC:-0}"
EOF
  chmod +x "$STUB_BIN/scp"
}

teardown() { rm -rf "$TMPDIR"; }

_load() {
  ERRS="$TMPDIR/errs"; : > "$ERRS"
  ui_error() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_info() { printf '%s\n' "$1" >> "$ERRS"; }; ui_status_ok() { printf 'OK: %s\n' "$1"; }
  ui_action() { :; }
  _dvw_log_action() { :; }
  source "$DVW_ROOT/lib/connect.sh"
  source "$DVW_ROOT/lib/push.sh"
  # Boundary stubs: target known, alias present.
  _dvw_push_resolve_target() { printf 'stubws\n'; }
  _dvw_ensure_ssh_alias() { return 0; }
}

@test "explicit file: scp to <ws>.devpod:/tmp/ and bare path as final line" {
  _load
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  run grep -qx 'stubws.devpod:/tmp/' "$SCP_ARGS"
  [ "$status" -eq 0 ]
}

@test "final stdout line is exactly the container path" {
  _load
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "${lines[-1]}" = "/tmp/shot.png" ]
}

@test "no args: pushes the newest fresh upload" {
  _load
  printf 'data' > "$TMPDIR/$UUID_A.png"
  run cmd_push
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "/tmp/$UUID_A.png" ]
}

@test "no args, nothing fresh: error explains filter and suggests explicit path" {
  _load
  run cmd_push
  [ "$status" -eq 1 ]
  run grep -q 'dvw push <file>' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "missing explicit file errors" {
  _load
  run cmd_push "$TMPDIR/nope.png"
  [ "$status" -eq 1 ]
  run grep -q 'nope.png' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "oversized explicit file errors naming the cap" {
  _load
  truncate -s 2M "$TMPDIR/big.bin"
  DVW_PUSH_MAX_SIZE_MB=1 run cmd_push "$TMPDIR/big.bin"
  [ "$status" -eq 1 ]
  run grep -q '1 MB' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "multiple files: first scp failure aborts the rest" {
  _load
  printf a > "$TMPDIR/one.png"; printf b > "$TMPDIR/two.png"
  SCP_STUB_RC=1 run cmd_push "$TMPDIR/one.png" "$TMPDIR/two.png"
  [ "$status" -ne 0 ]
  # scp stub logs one line per arg; the dest arg appears once per call
  run grep -c 'stubws.devpod:/tmp/' "$SCP_ARGS"
  [ "$output" = "1" ]
}

@test "--to is passed through to resolve_target" {
  _load
  _dvw_push_resolve_target() { printf '%s\n' "TO:${1:-none}" > "$TMPDIR/resolve-arg"; printf 'stubws\n'; }
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png" --to otherws
  [ "$(cat "$TMPDIR/resolve-arg")" = "TO:otherws" ]
}

@test "--clipboard and file args are mutually exclusive" {
  _load
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push --clipboard "$TMPDIR/shot.png"
  [ "$status" -eq 1 ]
  run grep -q 'clipboard' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "unknown flag errors with usage" {
  _load
  run cmd_push --bogus
  [ "$status" -eq 1 ]
  run grep -q 'usage' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "clipboard grab prefers wl-paste and writes a png" {
  _load
  cat > "$STUB_BIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
printf 'PNGDATA'
EOF
  chmod +x "$STUB_BIN/wl-paste"
  run _dvw_push_clipboard_grab
  [ "$status" -eq 0 ]
  [[ "$output" == *clip-*.png ]]
  [ "$(cat "$output")" = "PNGDATA" ]
}

@test "clipboard grab with no tool errors" {
  _load
  run _dvw_push_clipboard_grab
  [ "$status" -eq 1 ]
  run grep -qi 'clipboard' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "copy_path uses first available tool, silent no-op without one" {
  _load
  cat > "$STUB_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$TMPDIR/copied"
EOF
  chmod +x "$STUB_BIN/wl-copy"
  _dvw_push_copy_path "/tmp/x.png"
  [ "$(cat "$TMPDIR/copied")" = "/tmp/x.png" ]
  rm "$STUB_BIN/wl-copy" "$TMPDIR/copied"
  run _dvw_push_copy_path "/tmp/x.png"
  [ "$status" -eq 0 ]
}

@test "--dry-run prints would-be scp and transfers nothing" {
  _load
  # _dvw_run_or_print speaks through ui_info, which _load silences — give it
  # a voice for this test only.
  ui_info() { printf '%s\n' "$1"; }
  printf 'data' > "$TMPDIR/shot.png"
  DVW_DRY_RUN=1 run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run: scp"* ]]
  [ ! -s "$SCP_ARGS" ]
}
