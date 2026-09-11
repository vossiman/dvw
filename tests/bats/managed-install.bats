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

assert_active_one() {
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$status" -eq 0 ]
  [ "$output" = one ]
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
  mkdir -p "$source/tui"
  printf '[project]\nname = "fixture"\n' > "$source/tui/pyproject.toml"
  git -C "$source" init -q -b main
  git -C "$source" add -A
  git -C "$source" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
  sha=$(git -C "$source" rev-parse HEAD)
  printf '#!/usr/bin/env bash\nprintf "dirty working tree\\n"\n' > "$source/dvw"
  mkdir -p "$source/tui/.venv" "$source/tui/__pycache__"
  printf 'machine-local\n' > "$source/tui/.venv/private"
  printf 'cache\n' > "$source/tui/__pycache__/fixture.pyc"
  before=$(git -C "$source" status --porcelain=v1)

  run dvw_managed_install "$source" "$sha"
  [ "$status" -eq 0 ]
  [ "$(git -C "$source" rev-parse HEAD)" = "$sha" ]
  [ "$(git -C "$source" status --porcelain=v1)" = "$before" ]
  [ "$(cat "$AICODING_DATA_DIR/versions/dvw/$sha/.aicoding-version")" = "$sha" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
  [ -f "$AICODING_DATA_DIR/versions/dvw/$sha/tui/pyproject.toml" ]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$sha/tui/.venv" ]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$sha/tui/__pycache__" ]
}

@test "trusted marker snapshot excludes local environments and caches" {
  local source="$BATS_TEST_TMPDIR/source" release
  make_source "$source" "$SHA1" one
  mkdir -p "$source/tui/.venv" "$source/tui/__pycache__" "$source/tui/app"
  printf 'required source\n' > "$source/tui/app/main.py"
  printf 'machine-local\n' > "$source/tui/.venv/private"
  printf 'cache\n' > "$source/tui/__pycache__/fixture.pyc"

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -eq 0 ]
  release="$AICODING_DATA_DIR/versions/dvw/$SHA1"
  [ -f "$release/tui/app/main.py" ]
  [ ! -e "$release/tui/.venv" ]
  [ ! -e "$release/tui/__pycache__" ]
}

@test "managed install rejects resource symlinks" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  printf '# outside fixture\n' > "$BATS_TEST_TMPDIR/escape.sh"
  rm "$source/lib/version.sh"
  ln -s "$BATS_TEST_TMPDIR/escape.sh" "$source/lib/version.sh"

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged client validation failed"* ]]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
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

@test "failed release publication cannot activate or report success" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_publish_release() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"release publication failed"* ]]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$SHA2" ]
  assert_active_one
}

@test "published release is revalidated before activation" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  _dvw_managed_publish_release() {
    mv "$1" "$2"
    rm "$2/lib/version.sh"
  }

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"published release validation failed"* ]]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
  [ ! -e "$DVW_STATE_DIR/version" ]
  [ ! -e "$HOME/.local/bin/dvw" ]
}

@test "lock acquisition failure preserves the active install" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_acquire_lock() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not acquire install lock"* ]]
  [ ! -e "$AICODING_DATA_DIR/versions/dvw/$SHA2" ]
  assert_active_one
}

@test "launcher write failure preserves the active install" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_write_launcher() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"launcher staging failed"* ]]
  assert_active_one
}

@test "launcher chmod failure preserves the active install" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_chmod_launcher() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"launcher staging failed"* ]]
  assert_active_one
}

@test "marker directory failure preserves the active install" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_prepare_marker_dir() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"marker staging failed"* ]]
  assert_active_one
}

@test "marker write failure preserves the active install" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_write_marker() { return 1; }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"marker staging failed"* ]]
  assert_active_one
}

@test "launcher backup failure aborts before activation and preserves untouched state" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  local launcher_before marker_before current_before previous_before
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  launcher_before=$(sha256sum "$HOME/.local/bin/dvw")
  marker_before=$(sha256sum "$DVW_STATE_DIR/version")
  current_before=$(readlink "$AICODING_DATA_DIR/current/dvw")
  previous_before=$(readlink "$AICODING_DATA_DIR/previous/dvw" 2>/dev/null || printf absent)
  cp() {
    local destination="${@: -1}"
    [[ "$destination" == "$HOME/.local/bin/dvw.backup."* ]] && return 1
    command cp "$@"
  }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup preparation failed"* ]]
  [[ "$output" != *"previous release restored"* ]]
  [ "$(sha256sum "$HOME/.local/bin/dvw")" = "$launcher_before" ]
  [ "$(sha256sum "$DVW_STATE_DIR/version")" = "$marker_before" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$current_before" ]
  [ "$(readlink "$AICODING_DATA_DIR/previous/dvw" 2>/dev/null || printf absent)" = "$previous_before" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
  ! compgen -G "$HOME/.local/bin/dvw.backup.*" >/dev/null
  ! compgen -G "$DVW_STATE_DIR/version.backup.*" >/dev/null
}

@test "marker backup failure aborts before activation and preserves launcher and marker" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  local launcher_before marker_before current_before previous_before
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  launcher_before=$(sha256sum "$HOME/.local/bin/dvw")
  marker_before=$(sha256sum "$DVW_STATE_DIR/version")
  current_before=$(readlink "$AICODING_DATA_DIR/current/dvw")
  previous_before=$(readlink "$AICODING_DATA_DIR/previous/dvw" 2>/dev/null || printf absent)
  cp() {
    local destination="${@: -1}"
    [[ "$destination" == "$DVW_STATE_DIR/version.backup."* ]] && return 1
    command cp "$@"
  }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup preparation failed"* ]]
  [[ "$output" != *"previous release restored"* ]]
  [ "$(sha256sum "$HOME/.local/bin/dvw")" = "$launcher_before" ]
  [ "$(sha256sum "$DVW_STATE_DIR/version")" = "$marker_before" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$current_before" ]
  [ "$(readlink "$AICODING_DATA_DIR/previous/dvw" 2>/dev/null || printf absent)" = "$previous_before" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
  ! compgen -G "$HOME/.local/bin/dvw.backup.*" >/dev/null
  ! compgen -G "$DVW_STATE_DIR/version.backup.*" >/dev/null
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
  _dvw_managed_commit_marker() {
    "$HOME/.local/bin/dvw" > "$BATS_TEST_TMPDIR/during-failure"
    return 1
  }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/during-failure")" = one ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
}

@test "incomplete rollback keeps the recovery backup and reports its path" {
  local one="$BATS_TEST_TMPDIR/one" two="$BATS_TEST_TMPDIR/two"
  make_source "$one" "$SHA1" one
  make_source "$two" "$SHA2" two
  dvw_managed_install "$one" "$SHA1"
  _dvw_managed_commit_marker() {
    mv -f "$1" "$2"
    return 1
  }
  _dvw_managed_restore_file() {
    if [[ "$1" == "$DVW_STATE_DIR/version" ]]; then
      return 1
    fi
    mv -f "$2" "$1"
  }

  run dvw_managed_install "$two" "$SHA2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rollback incomplete"* ]]
  [[ "$output" == *"$DVW_STATE_DIR/version.backup."* ]]
  local recovery
  recovery=$(compgen -G "$DVW_STATE_DIR/version.backup.*")
  [ -f "$recovery" ]
  [ "$(cat "$recovery")" = "$SHA1" ]
  [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA2" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ]
}

@test "initial enrollment keeps a legacy launcher usable until the pointer is ready" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nprintf "legacy\\n"\n' > "$HOME/.local/bin/dvw"
  chmod +x "$HOME/.local/bin/dvw"
  _dvw_managed_commit_marker() {
    "$HOME/.local/bin/dvw" > "$BATS_TEST_TMPDIR/during-enrollment"
    mv -f "$1" "$2"
  }

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/during-enrollment")" = legacy ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = one ]
}

@test "initial launcher failure rolls marker and pointer back to the legacy command" {
  local source="$BATS_TEST_TMPDIR/source" legacy_hash
  make_source "$source" "$SHA1" one
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nprintf "legacy\\n"\n' > "$HOME/.local/bin/dvw"
  chmod +x "$HOME/.local/bin/dvw"
  legacy_hash=$(sha256sum "$HOME/.local/bin/dvw")
  _dvw_managed_commit_launcher() {
    [ "$(readlink "$AICODING_DATA_DIR/current/dvw")" = "$AICODING_DATA_DIR/versions/dvw/$SHA1" ] ||
      return 88
    [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ] || return 89
    return 1
  }

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$HOME/.local/bin/dvw")" = "$legacy_hash" ]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
  [ ! -e "$DVW_STATE_DIR/version" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = legacy ]
}

@test "interrupted initial enrollment restores legacy launcher marker and pointer" {
  local source="$BATS_TEST_TMPDIR/source" legacy_hash
  make_source "$source" "$SHA1" one
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nprintf "legacy\\n"\n' > "$HOME/.local/bin/dvw"
  chmod +x "$HOME/.local/bin/dvw"
  legacy_hash=$(sha256sum "$HOME/.local/bin/dvw")
  _dvw_managed_commit_launcher() {
    [ -L "$AICODING_DATA_DIR/current/dvw" ] || return 88
    [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ] || return 89
    : > "$BATS_TEST_TMPDIR/saw-staged-enrollment"
    kill -TERM "$BASHPID"
  }

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -eq 143 ]
  [[ "$output" == *"interrupted by TERM"* ]]
  [ -e "$BATS_TEST_TMPDIR/saw-staged-enrollment" ]
  [ "$(sha256sum "$HOME/.local/bin/dvw")" = "$legacy_hash" ]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
  [ ! -e "$DVW_STATE_DIR/version" ]
  run "$HOME/.local/bin/dvw"
  [ "$output" = legacy ]
}

@test "fresh enrollment launcher failure removes prepared marker and pointer" {
  local source="$BATS_TEST_TMPDIR/source"
  make_source "$source" "$SHA1" one
  _dvw_managed_commit_launcher() {
    [ -L "$AICODING_DATA_DIR/current/dvw" ] || return 88
    [ "$(cat "$DVW_STATE_DIR/version")" = "$SHA1" ] || return 89
    return 1
  }

  run dvw_managed_install "$source" "$SHA1"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.local/bin/dvw" ]
  [ ! -e "$AICODING_DATA_DIR/current/dvw" ]
  [ ! -e "$DVW_STATE_DIR/version" ]
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
