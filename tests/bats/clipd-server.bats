#!/usr/bin/env bats
# dvw-clipd HTTP-over-unix-socket server: images-only enforcement, targets
# listing, byte-exact clip fetch, 404 on empty clipboard. Runs the real
# python3 server against stubbed clipboard tools; curl is the client, same
# as the container shims.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  SOCK="$TMPDIR/clip.sock"
  # Deterministic backend for tests; auto-detection is covered separately.
  export DVW_CLIPD_BACKEND=wayland
  PNG_FIXTURE="$TMPDIR/fixture.png"
  # Real 1x1 PNG, not pretend bytes: magic-byte handling must be honest.
  printf '\x89PNG\r\n\x1a\n' > "$PNG_FIXTURE"
  printf 'IMAGEDATA' >> "$PNG_FIXTURE"
  cat > "$STUB_BIN/wl-paste" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-l" || "\$1" == "--list-types" ]]; then
  cat "$TMPDIR/types"
  exit 0
fi
# --type <mime>
if [[ -s "$TMPDIR/clipdata" ]]; then cat "$TMPDIR/clipdata"; exit 0; fi
exit 1
EOF
  chmod +x "$STUB_BIN/wl-paste"
  printf 'image/png\ntext/plain;charset=utf-8\nimage/jpeg\n' > "$TMPDIR/types"
  cp "$PNG_FIXTURE" "$TMPDIR/clipdata"
}

teardown() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}

_start_server() {
  python3 "$DVW_ROOT/clipd/dvw-clipd.py" --socket "$SOCK" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  echo "server socket never appeared" >&2
  return 1
}

@test "clipd: /targets lists only image mime types" {
  _start_server
  run -0 curl -s --unix-socket "$SOCK" http://x/targets
  [[ "$output" == *"image/png"* ]]
  [[ "$output" == *"image/jpeg"* ]]
  [[ "$output" != *"text/plain"* ]]
}

@test "clipd: /targets is empty when clipboard has no image formats" {
  printf 'text/plain;charset=utf-8\n' > "$TMPDIR/types"
  _start_server
  run -0 curl -s --unix-socket "$SOCK" http://x/targets
  [[ -z "$output" ]]
}

@test "clipd: /clip returns image bytes exactly" {
  _start_server
  curl -s --unix-socket "$SOCK" 'http://x/clip?type=image/png' -o "$TMPDIR/got.png"
  cmp "$TMPDIR/got.png" "$PNG_FIXTURE"
}

@test "clipd: non-image type is refused with 403 (images-only boundary)" {
  _start_server
  run -0 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" 'http://x/clip?type=text/plain'
  [[ "$output" == "403" ]]
}

@test "clipd: unknown path is refused with 403" {
  _start_server
  run -0 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" http://x/anything
  [[ "$output" == "403" ]]
}

@test "clipd: empty clipboard yields 404" {
  : > "$TMPDIR/clipdata"
  _start_server
  run -0 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" 'http://x/clip?type=image/png'
  [[ "$output" == "404" ]]
}

@test "clipd: stale socket file is replaced on startup" {
  touch "$SOCK"
  _start_server
  run -0 curl -s --unix-socket "$SOCK" http://x/targets
  [[ "$output" == *"image/png"* ]]
}

@test "clipd: missing backend tool yields empty targets and 404, never a crash" {
  # Regression: on WSL without Windows PATH interop, powershell.exe was
  # absent, the spawn raised FileNotFoundError, the handler died, and every
  # request surfaced as curl 52 "empty reply" (live failure, 2026-08-27).
  export DVW_CLIPD_BACKEND=wsl   # container has no powershell.exe at all
  _start_server
  run -0 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" http://x/targets
  [[ "$output" == "200" ]]
  run -0 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" 'http://x/clip?type=image/png'
  [[ "$output" == "404" ]]
}

@test "clipd: powershell.exe resolves via absolute fallback when not on PATH" {
  export DVW_CLIPD_BACKEND=wsl
  FAKE_WIN="$TMPDIR/mnt/c/Windows/System32/WindowsPowerShell/v1.0"
  mkdir -p "$FAKE_WIN"
  cat > "$FAKE_WIN/powershell.exe" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$FAKE_WIN/powershell.exe"
  export DVW_CLIPD_POWERSHELL="$FAKE_WIN/powershell.exe"
  _start_server
  run -0 curl -s --unix-socket "$SOCK" http://x/targets
  [[ "$output" == "image/png" ]]
}
