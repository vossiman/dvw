#!/usr/bin/env bats
setup() {
  DVW_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$DVW_ROOT/install-bastion.sh"
  TMPDIR=$(mktemp -d); export HOME="$TMPDIR"
  export XDG_CONFIG_HOME="$HOME/.config" DVW_CONFIG="$HOME/.config/dvw/config"
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

@test "enables the push watcher in the dvw config; DVW_BASTION_NO_WATCH=1 skips it" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  run bash "$SCRIPT"
  grep -qx 'DVW_PUSH_WATCH=1' "$HOME/.config/dvw/config"
  echo "$output" | grep -q 'push watcher enabled'
  rm -f "$HOME/.config/dvw/config"
  DVW_BASTION_NO_WATCH=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.config/dvw/config" ]
  echo "$output" | grep -q 'push watcher skipped'
}

@test "a hand-set DVW_PUSH_WATCH=0 survives re-running the installer" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  mkdir -p "$HOME/.config/dvw"; printf 'DVW_PUSH_WATCH=0\n' > "$HOME/.config/dvw/config"
  run bash "$SCRIPT"
  grep -qx 'DVW_PUSH_WATCH=0' "$HOME/.config/dvw/config"
  echo "$output" | grep -q 'disabled by hand'
}

@test "check mode reports the watcher flag without writing it" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  run bash "$SCRIPT" --check
  [ ! -f "$HOME/.config/dvw/config" ]
  echo "$output" | grep -q 'push watcher not enabled'
  mkdir -p "$HOME/.config/dvw"; printf 'DVW_PUSH_WATCH=1\n' > "$HOME/.config/dvw/config"
  run bash "$SCRIPT" --check
  echo "$output" | grep -q 'push watcher enabled'
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

@test "unattended Pi enrollment delegates the selected source without installing a harness" {
  local sha="1234567890abcdef1234567890abcdef12345678"
  local selected="$HOME/selected-dvw"
  mkdir -p "$selected"
  cat > "$selected/dvw-install.sh" <<'EOF'
#!/bin/sh
printf 'dvw-install %s\n' "$*" >> "$HOME/calls"
EOF
  chmod +x "$selected/dvw-install.sh"
  # Neither PATH shadowing nor unavailable SSH/devpod belongs to enrollment.
  for command in dvw-install.sh ssh curl devpod; do
    printf '#!/bin/sh\necho "forbidden %s" >> "$HOME/calls"\nexit 97\n' "$command" > "$HOME/stubs/$command"
    chmod +x "$HOME/stubs/$command"
  done
  cat > "$HOME/stubs/aicoding-auto-update" <<'EOF'
#!/bin/sh
printf 'aicoding-auto-update %s\n' "$*" >> "$HOME/calls"
EOF
  chmod +x "$HOME/stubs/aicoding-auto-update"

  run bash "$SCRIPT" --unattended --source "$selected" --version "$sha"
  [ "$status" -eq 0 ]
  grep -qx "dvw-install --unattended --source $selected --version $sha" "$HOME/calls"
  grep -qx "aicoding-auto-update --ensure" "$HOME/calls"
  [ "$(wc -l < "$HOME/calls")" -eq 2 ]
  [ ! -e "$HOME/.config/dvw/config" ]
  [[ "$output" == *"enrollment requested"* ]]
}

@test "failed selected Pi adapter does not request scheduler or run legacy setup" {
  local selected="$HOME/selected-dvw"
  mkdir -p "$selected"
  printf '#!/bin/sh\nexit 42\n' > "$selected/dvw-install.sh"
  printf '#!/bin/sh\necho unexpected >> "$HOME/calls"\n' > "$HOME/stubs/aicoding-auto-update"
  chmod +x "$selected/dvw-install.sh" "$HOME/stubs/aicoding-auto-update"
  run bash "$SCRIPT" --unattended --source "$selected" --version 1234567890abcdef1234567890abcdef12345678
  [ "$status" -eq 42 ]
  [ ! -e "$HOME/calls" ]
  [ ! -e "$HOME/.config/dvw/config" ]
}

@test "unattended Pi enrollment requires the common runtime before changing dvw" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  local sha="1234567890abcdef1234567890abcdef12345678"

  run bash "$SCRIPT" --unattended --source /tmp/selected-dvw --version "$sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"minimal common updater missing"* ]]
  ! grep -q 'dvw-install' "$HOME/calls"
}

@test "unattended Pi enrollment requires a full source/version pair" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/devpod"; chmod +x "$HOME/.local/bin/devpod"
  run bash "$SCRIPT" --unattended --source /tmp/selected-dvw
  [ "$status" -ne 0 ]
  [[ "$output" == *"--source PATH --version SHA"* ]]
}
