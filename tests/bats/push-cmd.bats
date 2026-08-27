#!/usr/bin/env bats
# cmd_push: argv contract, scp invocation shape, output contract (bare
# container path as final stdout line), size/existence errors, --clipboard
# helper selection, --dry-run. scp/clipboard tools stubbed on PATH;
# resolve-target and alias registration stubbed at the function boundary.

bats_require_minimum_version 1.5.0

UUID_A="570d7e98-a20a-4e6a-ab30-c4b3400ae490"

# Every external tool the clipboard paths in lib/push.sh probe for. These must
# be UNREACHABLE from the test PATH: several tests below assert the "no
# clipboard tool present" branch, and absence cannot be faked with a stub.
# See tests/bats/lib/sanitized-path.bash for the rationale and the incident
# that produced it.
CLIP_TOOLS="wl-copy wl-paste xclip xsel pbcopy clip.exe powershell.exe wslpath"

setup_file() {
  load "lib/sanitized-path.bash"
  # shellcheck disable=SC2086  # word splitting is intended
  sanitized_bin_init "$BATS_FILE_TMPDIR/sanitized-bin" $CLIP_TOOLS
}

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$SANITIZED_BIN"
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
  source "$DVW_ROOT/lib/wsl-bridge.sh"
  source "$DVW_ROOT/lib/push.sh"
  # Boundary stubs: target known and running, alias present.
  _dvw_push_resolve_target() { printf 'stubws\n'; }
  _dvw_ws_container_state() { echo yes; }
  _dvw_ensure_ssh_alias() { return 0; }
  _dvw_ensure_local_devpod_state() { return 0; }
}

# Guard: if this fails, the sanitized PATH stopped working and the clipboard
# tests below are silently exercising the host's real tools (see CLIP_TOOLS).
@test "no real clipboard tool is reachable from the test PATH" {
  for t in $CLIP_TOOLS; do
    run command -v "$t"
    [ "$status" -ne 0 ] || {
      echo "reachable: $t -> $output" >&2
      false
    }
  done
}

@test "sanitized PATH still provides ordinary binaries" {
  run command -v cat
  [ "$status" -eq 0 ]
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

@test "local devpod state guard failure aborts before scp, alias untouched" {
  _load
  _dvw_ensure_local_devpod_state() { return 1; }
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "$status" -ne 0 ]
  [ ! -s "$SCP_ARGS" ]
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

@test "copy_path uses first available tool, rc 0 with a tool present" {
  _load
  cat > "$STUB_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$TMPDIR/copied"
EOF
  chmod +x "$STUB_BIN/wl-copy"
  run _dvw_push_copy_path "/tmp/x.png"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/copied")" = "/tmp/x.png" ]
}

@test "copy_path is silent no-op returning rc 1 without a tool" {
  _load
  run _dvw_push_copy_path "/tmp/x.png"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "--dry-run prints would-be scp, transfers nothing, no phantom final path" {
  _load
  # _dvw_run_or_print speaks through ui_info, which _load silences — give it
  # a voice for this test only.
  ui_info() { printf '%s\n' "$1"; }
  printf 'data' > "$TMPDIR/shot.png"
  DVW_DRY_RUN=1 run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run: scp"* ]]
  [ ! -s "$SCP_ARGS" ]
  run grep -qx '/tmp/shot.png' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "colon/dash-leading relative source is rewritten with ./ for scp" {
  _load
  cd "$TMPDIR"
  printf 'data' > "foo:bar.png"
  run cmd_push "foo:bar.png"
  [ "$status" -eq 0 ]
  run grep -qx './foo:bar.png' "$SCP_ARGS"
  [ "$status" -eq 0 ]
}

@test "-- terminates options: a --prefixed filename is pushed, ./-rewritten" {
  _load
  cd "$TMPDIR"
  printf 'data' > "./--weird.png"
  run cmd_push -- --weird.png
  [ "$status" -eq 0 ]
  run grep -qx './--weird.png' "$SCP_ARGS"
  [ "$status" -eq 0 ]
}

@test "stopped workspace is refused before scp even with a live session" {
  _load
  _dvw_ws_container_state() { echo no; }
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 1 ]
  [ ! -s "$SCP_ARGS" ]
  run grep -q 'not running' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "unreachable catalog is refused before scp, not guessed" {
  _load
  _dvw_ws_container_state() { echo unknown; }
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 1 ]
  [ ! -s "$SCP_ARGS" ]
  run grep -qi 'catalog' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "clipboard temp file is removed after a successful push" {
  _load
  cat > "$STUB_BIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
printf 'PNGDATA'
EOF
  chmod +x "$STUB_BIN/wl-paste"
  run cmd_push --clipboard
  [ "$status" -eq 0 ]
  run bash -c 'ls "$TMPDIR"/clip-*.png 2>/dev/null'
  [ -z "$output" ]
}

@test "clipboard temp file is removed after a failed transfer" {
  _load
  cat > "$STUB_BIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
printf 'PNGDATA'
EOF
  chmod +x "$STUB_BIN/wl-paste"
  SCP_STUB_RC=1 run cmd_push --clipboard
  [ "$status" -ne 0 ]
  run bash -c 'ls "$TMPDIR"/clip-*.png 2>/dev/null'
  [ -z "$output" ]
}

@test "clipboard grab with no tool leaves no temp file behind" {
  _load
  run _dvw_push_clipboard_grab
  [ "$status" -eq 1 ]
  run bash -c 'ls "$TMPDIR"/clip-*.png 2>/dev/null'
  [ -z "$output" ]
}

@test "clipboard grab WSL wslpath failure leaves no temp file behind" {
  _load
  cat > "$STUB_BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_BIN/powershell.exe"
  cat > "$STUB_BIN/wslpath" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/wslpath"
  run _dvw_push_clipboard_grab
  [ "$status" -eq 1 ]
  run bash -c 'ls "$TMPDIR"/clip-*.png 2>/dev/null'
  [ -z "$output" ]
}

@test "copy_path returns nonzero when the only tool present fails" {
  _load
  cat > "$STUB_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/wl-copy"
  run _dvw_push_copy_path "/tmp/x.png"
  [ "$status" -eq 1 ]
}

@test "copy_path falls back to the next tool when the first fails" {
  _load
  cat > "$STUB_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$STUB_BIN/xclip" <<'EOF'
#!/usr/bin/env bash
cat > "$TMPDIR/copied"
EOF
  chmod +x "$STUB_BIN/wl-copy" "$STUB_BIN/xclip"
  run _dvw_push_copy_path "/tmp/x.png"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/copied")" = "/tmp/x.png" ]
}

@test "failing clipboard tool: push succeeds but never claims a copy" {
  _load
  cat > "$STUB_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/wl-copy"
  printf 'data' > "$TMPDIR/shot.png"
  run cmd_push "$TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  [[ "$output" != *"copied to clipboard"* ]]
}

@test "clipboard grab on WSL uses powershell even when wl-paste is installed" {
  # WSLg ships wl-paste but bridges clipboard images as image/bmp only, so
  # `wl-paste --type image/png` fails without falling through — the WSL
  # detection must outrank tool discovery (R3 finding, clipboard-bridge spec).
  _load
  export WSL_DISTRO_NAME=Ubuntu
  cat > "$STUB_BIN/wl-paste" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  cat > "$STUB_BIN/wslpath" <<'STUB'
#!/usr/bin/env bash
printf 'C:\\fake\\%s\n' "$(basename "$2")"
STUB
  cat > "$STUB_BIN/powershell.exe" <<'STUB'
#!/usr/bin/env bash
# fake grab: find the target path in the -Command payload via the marker
# file the test wrote; just write PNG bytes where the caller expects them.
printf 'PSDATA' > "$(cat "$TMPDIR/expected-out")"
exit 0
STUB
  chmod +x "$STUB_BIN/wl-paste" "$STUB_BIN/wslpath" "$STUB_BIN/powershell.exe"
  # The grab passes a mktemp path into powershell via wslpath; intercept it.
  mktemp() { command mktemp "$@" | tee "$TMPDIR/mktemp-out"; }
  export -f mktemp
  # povershell stub needs the real out path: wire it through a file.
  ln -sf "$TMPDIR/mktemp-out" "$TMPDIR/expected-out"
  run _dvw_push_clipboard_grab
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "PSDATA" ]
  unset WSL_DISTRO_NAME
}
