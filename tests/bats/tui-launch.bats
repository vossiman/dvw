#!/usr/bin/env bats
# Launcher decision logic for the Textual TUI. Pure-function tests; the
# socket-forward path is exercised with stubbed ssh/curl on PATH.

setup() {
  REAL_ROOT="${BATS_TEST_DIRNAME}/../.."
  source "$REAL_ROOT/lib/tui-launch.sh"
  # Fake root so the tui/ presence check is controllable (the real tui/
  # directory only appears in Task 2).
  DVW_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$DVW_ROOT/tui"
  export DVW_ROOT
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# --- _dvw_tui_available -----------------------------------------------------

@test "_dvw_tui_available: no tui/ dir disables" {
  rm -rf "$DVW_ROOT/tui"
  DVW_TUI_FORCE=1 run _dvw_tui_available
  [ "$status" -ne 0 ]
}

@test "_dvw_tui_available: DVW_NO_TUI=1 disables" {
  DVW_NO_TUI=1 DVW_TUI_FORCE=1 run _dvw_tui_available
  [ "$status" -ne 0 ]
}

@test "_dvw_tui_available: missing uv disables" {
  # no uv stub on purpose — STUB_DIR has no uv binary
  PATH="$STUB_DIR" DVW_TUI_FORCE=1 run _dvw_tui_available
  [ "$status" -ne 0 ]
}

@test "_dvw_tui_available: non-tty without force disables" {
  # bats runs without a tty, so the -t checks fail naturally.
  printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/uv"; chmod +x "$STUB_DIR/uv"
  PATH="$STUB_DIR:$PATH" DVW_TUI_FORCE= run _dvw_tui_available
  [ "$status" -ne 0 ]
}

@test "_dvw_tui_available: uv present + force succeeds" {
  printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/uv"; chmod +x "$STUB_DIR/uv"
  PATH="$STUB_DIR:$PATH" DVW_TUI_FORCE=1 run _dvw_tui_available
  [ "$status" -eq 0 ]
}

# --- _dvw_tui_ensure_socket ---------------------------------------------------

@test "_dvw_tui_ensure_socket: local service socket wins" {
  local sock="$BATS_TEST_TMPDIR/catalog.sock"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$sock"
  DVW_CATALOG_SOCK="$sock" run _dvw_tui_ensure_socket
  [ "$status" -eq 0 ]
  [ "$output" = "$sock" ]
}

@test "_dvw_tui_ensure_socket: forwards via ssh when no local socket" {
  # Stub ssh: record argv, create the forward socket like a real -L would.
  cat > "$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$BATS_TEST_TMPDIR/ssh-argv"
fwd=\$(printf '%s\n' "\$@" | grep -A1 '^-L\$' | tail -1)
fwd="\${fwd%%:*}"
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "\$fwd"
EOF
  chmod +x "$STUB_DIR/ssh"
  PATH="$STUB_DIR:$PATH" \
    DVW_CATALOG_SOCK=/nonexistent/catalog.sock \
    DVW_CATALOG_HOST=testhost \
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" \
    run _dvw_tui_ensure_socket
  [ "$status" -eq 0 ]
  [[ "$output" == "$BATS_TEST_TMPDIR/dvw-catalog-fwd-"*".sock" ]]
  grep -q "testhost" "$BATS_TEST_TMPDIR/ssh-argv"
}

@test "_dvw_tui_ensure_socket: ssh failure returns nonzero" {
  printf '#!/bin/sh\nexit 255\n' > "$STUB_DIR/ssh"; chmod +x "$STUB_DIR/ssh"
  PATH="$STUB_DIR:$PATH" \
    DVW_CATALOG_SOCK=/nonexistent/catalog.sock \
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" \
    run _dvw_tui_ensure_socket
  [ "$status" -ne 0 ]
}

@test "_dvw_tui_ensure_socket: healthy forward socket is reused without ssh" {
  local fwd="$BATS_TEST_TMPDIR/dvw-catalog-fwd-$(id -u).sock"
  # Create a real AF_UNIX socket at the forward path to satisfy [[ -S ]]
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$fwd"
  # Stub curl to succeed (socket is "healthy")
  printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/curl"; chmod +x "$STUB_DIR/curl"
  # Stub ssh to record a marker and fail — it must NOT be called
  local marker="$BATS_TEST_TMPDIR/ssh-called"
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$marker" > "$STUB_DIR/ssh"; chmod +x "$STUB_DIR/ssh"
  PATH="$STUB_DIR:$PATH" \
    DVW_CATALOG_SOCK=/nonexistent/catalog.sock \
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" \
    run _dvw_tui_ensure_socket
  [ "$status" -eq 0 ]
  [ "$output" = "$fwd" ]
  [ ! -f "$marker" ]
}
