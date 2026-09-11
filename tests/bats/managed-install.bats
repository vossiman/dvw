#!/usr/bin/env bats

setup() {
  : "${DVW_ROOT:?}"
  export HOME="$BATS_TEST_TMPDIR/home"
  export AICODING_DATA_DIR="$BATS_TEST_TMPDIR/share/aicoding"
  export DVW_STATE_DIR="$BATS_TEST_TMPDIR/state/dvw"
  mkdir -p "$HOME"
  source "$DVW_ROOT/lib/managed-install.sh"
  SHA1="1111111111111111111111111111111111111111"
  SHA2="2222222222222222222222222222222222222222"
}

make_source() {
  local dir="$1" sha="$2" label="$3"
  mkdir -p "$dir/lib"
  printf '%s\n' "$sha" > "$dir/.aicoding-version"
  cat > "$dir/dvw" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$label'
EOF
  chmod +x "$dir/dvw"
  local lib
  for lib in catalog catalog-http-lib config ssh-sync wsl-bridge clipd connect connect-resolver \
    push pull push-watch commands wizard pin pin-rebuild ui update-check \
    update-super tui-launch version win-ssh-proxy; do
    printf '# fixture\n' > "$dir/lib/$lib.sh"
  done
}

@test "managed install stages an immutable release and launches it" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -eq 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(cat "$AICODING_DATA_DIR/versions/dvw/$SHA1/.aicoding-version")" = "$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$status" -eq 0 ]
  [ "$output" = one ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ]
}

@test "managed activation preserves previous and launcher follows current" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  dvw_managed_install "$two" "$SHA2"

  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA2" ]
  [ "$(readlink "$AICODING_DATA_DIR/previous/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = two ]
}

@test "a running process keeps its immutable resources across activation" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  printf 'printf "one\\n"\n' > "$one/lib/late.sh"
  printf 'printf "two\\n"\n' > "$two/lib/late.sh"
  for source in "$one" "$two"; do
    cat > "$source/dvw" <<'EOF'
#!/usr/bin/env bash
root=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
if [[ -n "${DVW_TEST_READY:-}" ]]; then
  : > "$DVW_TEST_READY"
  while [[ ! -e "$DVW_TEST_GO" ]]; do sleep 0.02; done
fi
. "$root/lib/late.sh"
EOF
    chmod +x "$source/dvw"
  done
  dvw_managed_install "$one" "$SHA1"

  export DVW_TEST_READY="$BATS_TEST_TMPDIR/ready"
  export DVW_TEST_GO="$BATS_TEST_TMPDIR/go"
  "$HOME/.local/bin/dvw" > "$BATS_TEST_TMPDIR/old-output" &
  local old_pid=$!
  for _ in {1..100}; do [[ -e "$DVW_TEST_READY" ]] && break; sleep 0.02; done
  [[ -e "$DVW_TEST_READY" ]]
  dvw_managed_install "$two" "$SHA2"
  : > "$DVW_TEST_GO"
  wait "$old_pid"
  [ "$(cat "$BATS_TEST_TMPDIR/old-output")" = one ]

  unset DVW_TEST_READY DVW_TEST_GO
  run "$HOME/.local/bin/dvw"
  [ "$output" = two ]
}

@test "managed install refuses a non-full SHA before writing" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  run dvw_managed_install "$source" deadbeef
  [ "$status" -ne 0 ]
  [[ "$output" == *"full SHA"* ]]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
}

@test "managed install refuses source version mismatch before writing" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  run dvw_managed_install "$source" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source version mismatch"* ]]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
}

@test "managed install accepts an exact git checkout without mutating it" {
  local source="$BATS_TEST_TMPDIR/source" before sha
  make_source "$source" "$SHA1" one
  rm "$source/.aicoding-version"
  git -C "$source" init -q -b main
  git -C "$source" add -A
  git -C "$source" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
  sha=$(git -C "$source" rev-parse HEAD)
  before=$(git -C "$source" status --porcelain=v1)

  run dvw_managed_install "$source" "$sha"
  [ "$status" -eq 0 ]
  [ "$(git -C "$source" rev-parse HEAD)" = "$sha" ]
  [ "$(git -C "$source" status --porcelain=v1)" = "$before" ]
  [ "$(cat "$AICODING_DATA_DIR/versions/dvw/$sha/.aicoding-version")" = "$sha" ]
}

@test "failed validation leaves the active release and source unchanged" {
  local good="$BATS_TEST_TMPDIR/good" bad="$BATS_TEST_TMPDIR/bad"
  make_source "$good" "$SHA1" one
  make_source "$bad" "$SHA2" broken
  printf '#!/usr/bin/env bash\nif then\n' > "$bad/dvw"
  local before
  before=$(find "$bad" -type f -exec sha256sum {} + | sort | sha256sum)
  dvw_managed_install "$good" "$SHA1"

  run dvw_managed_install "$bad" "$SHA2"
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(find "$bad" -type f -exec sha256sum {} + | sort | sha256sum)" = "$before" ]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$SHA2" ]
}

@test "managed install rejects a release missing a required client library" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  rm "$source/lib/catalog-http-lib.sh"

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged client validation failed"* ]]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
}

@test "launcher commit failure rolls back current launcher and version marker" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_commit_launcher() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
}

@test "marker commit failure rolls back current launcher and version marker" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_commit_marker() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
}

@test "dvw-install unattended path performs only the managed client install" {
  local source="$BATS_TEST_TMPDIR/source" stubs="$BATS_TEST_TMPDIR/stubs"
  make_source "$source" "$SHA1" one
  mkdir -p "$stubs"
  for command_name in sudo systemctl devpod; do
    cat > "$stubs/$command_name" <<EOF
#!/bin/sh
echo '$command_name SHOULD NOT RUN' >&2
exit 99
EOF
    chmod +x "$stubs/$command_name"
  done

  PATH="$stubs:$PATH" run bash "$DVW_ROOT/dvw-install.sh" \
    --unattended --source "$source" --version "$SHA1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
}

@test "dvw-install unattended path requires source and version together" {
  run bash "$DVW_ROOT/dvw-install.sh" --unattended --source "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--source PATH --version SHA"* ]]
}

@test "asset selection maps Linux machine architectures" {
  uname() { printf 'x86_64\n'; }
  run dvw_devpod_download_url
  [ "$output" = "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64" ]

  uname() { printf 'aarch64\n'; }
  run dvw_devpod_download_url
  [ "$output" = "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-arm64" ]
}

@test "asset selection rejects unsupported architectures" {
  uname() { printf 'riscv64\n'; }
  run dvw_devpod_download_url
  [ "$status" -ne 0 ]
}
