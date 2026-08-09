#!/usr/bin/env bats
setup() {
  DVW_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$DVW_ROOT/install-bastion.sh"
  TMPDIR=$(mktemp -d); export HOME="$TMPDIR"
  mkdir -p "$HOME/stubs" "$HOME/.local/bin"
  for b in ssh curl; do
    printf '#!/bin/sh\necho "%s $*" >> "$HOME/calls"\n' "$b" > "$HOME/stubs/$b"
  done
  printf '#!/bin/sh\necho "uname $*" >> "$HOME/calls"\necho aarch64\n' > "$HOME/stubs/uname"
  printf '#!/bin/sh\necho "dvw-install" >> "$HOME/calls"\n' > "$HOME/stubs/dvw-install.sh"
  chmod +x "$HOME/stubs/"*
  # Replace (not prepend to) PATH: this host may have a real devpod on
  # /usr/local/bin (dev container base image), which would defeat the
  # "devpod missing" scenario below. Keep only the stub dir plus the
  # standard system dirs holding coreutils/bash itself.
  export PATH="$HOME/stubs:/usr/bin:/bin"
  export DVW_BASTION_SKIP_NETWORK=1
}
teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

@test "check mode reports missing devpod as FAIL, present as OK" {
  run bash "$SCRIPT" --check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'devpod.*FAIL\|FAIL.*devpod'
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  run bash "$SCRIPT" --check
  echo "$output" | grep -qi 'devpod.*OK\|OK.*devpod'
}

@test "skip-network guard blocks the devpod download" {
  run bash "$SCRIPT"
  run grep 'curl.*devpod' "$HOME/calls"
  [ "$status" -ne 0 ]
}

@test "delegates dvw client install to dvw-install.sh" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  run bash "$SCRIPT"
  grep -q 'dvw-install' "$HOME/calls"
}

@test "dvw-install.sh sees a devpod that exists only at ~/.local/bin (fresh-Pi PATH bug)" {
  # Regression for: install-bastion.sh used to delegate via
  # `PATH="$PATH:$HERE" dvw-install.sh`, i.e. ~/.local/bin (where step 1
  # drops a freshly-downloaded arm64 devpod) was never added to PATH. On a
  # fresh Raspberry Pi shell without ~/.local/bin already on PATH,
  # dvw-install.sh's own `command -v devpod` probe would then miss the
  # binary it just installed and sudo-install its hardcoded amd64 build to
  # /usr/local/bin instead, permanently shadowing the working arm64 one.
  #
  # This stub records the PATH it's invoked with and whether `command -v
  # devpod` can see the ~/.local/bin copy, standing in for dvw-install.sh's
  # real probe.
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  cat > "$HOME/stubs/dvw-install.sh" <<'EOF'
#!/bin/sh
echo "PATH=$PATH" >> "$HOME/calls"
if command -v devpod >/dev/null 2>&1; then
  echo "dvw-install-sees-devpod: $(command -v devpod)" >> "$HOME/calls"
else
  echo "dvw-install-sees-devpod: NONE" >> "$HOME/calls"
fi
EOF
  chmod +x "$HOME/stubs/dvw-install.sh"
  run bash "$SCRIPT"
  grep -q "dvw-install-sees-devpod: $HOME/.local/bin/devpod" "$HOME/calls"
}
