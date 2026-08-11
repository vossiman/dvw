#!/usr/bin/env bats
#
# cmd_new flag-driven flow (gum wizard removed 2026-08-11). Local bare
# repos stand in for remotes; devpod + catalog are stubbed.

setup() {
  source "$DVW_ROOT/dvw"
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$BATS_TEST_TMPDIR/absent.json"
  # A "remote" with one commit on main.
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  (
    tmp=$(mktemp -d) && cd "$tmp" && git init -q -b main \
      && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
      && git remote add origin "$REMOTE" && git push -q origin main
  )
  EMPTY_REMOTE="$BATS_TEST_TMPDIR/empty.git"
  git init -q --bare "$EMPTY_REMOTE"
  # A "remote" with one commit on main that already carries a devcontainer.
  DEVC_REMOTE="$BATS_TEST_TMPDIR/devc.git"
  git init -q --bare "$DEVC_REMOTE"
  (
    tmp=$(mktemp -d) && cd "$tmp" && git init -q -b main \
      && mkdir -p .devcontainer && printf '{"stub": true}\n' > .devcontainer/devcontainer.json \
      && git add -A \
      && git -c user.name=t -c user.email=t@t commit -q -m init \
      && git remote add origin "$DEVC_REMOTE" && git push -q origin main
  )
  # Stubs: catalog knows nothing, devpod succeeds and records.
  catalog_workspace_get() { return 1; }
  catalog_default() { :; }
  catalog_workspace_add() { echo "cat-add:$1" >> "$BATS_TEST_TMPDIR/calls"; }
  catalog_repo_upsert() { :; }
  catalog_workspace_set_devpod_state() { :; }
  devpod() {
    case "$1" in
      list) printf '[]' ;;
      up) echo "up:$2" >> "$BATS_TEST_TMPDIR/calls" ;;
    esac
  }
}

@test "cmd_new: missing --repo errors with usage" {
  run cmd_new --name x --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--repo"
  echo "$output" | grep -q "usage: dvw new"
}

@test "cmd_new: bad --ide errors" {
  run cmd_new --repo "$REMOTE" --branch main --name x --ide vim --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ide"
}

@test "cmd_new: --repo followed by a flag-shaped value errors with usage" {
  run cmd_new --repo --name x --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "usage: dvw new"
}

# _new_resolve_branches retries the SSH form when the HTTPS form fails (no
# credential helper in the devbox). Stub _fetch_remote_branches directly —
# fail for the https URL, succeed for its ssh equivalent — which matches
# what _github_https_to_ssh would actually produce, and confirms cmd_new
# surfaces the swap to the user instead of silently using a different URL
# than the one they passed.
@test "cmd_new: notes the HTTPS->SSH swap when the resolved repo URL differs from the one passed" {
  _fetch_remote_branches() {
    case "$1" in
      https://github.com/foo/bar.git) return 1 ;;
      git@github.com:foo/bar.git) printf 'main\n'; return 0 ;;
      *) return 1 ;;
    esac
  }
  run cmd_new --repo https://github.com/foo/bar.git --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "using SSH form for github"
  echo "$output" | grep -q "git@github.com:foo/bar.git"
}

@test "cmd_new: happy path creates workspace non-interactively" {
  run cmd_new --repo "$REMOTE" --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 0 ]
  grep -q "up:${REMOTE}@main" "$BATS_TEST_TMPDIR/calls"
  grep -q "cat-add:wsx" "$BATS_TEST_TMPDIR/calls"
}

@test "cmd_new: nonexistent branch errors naming available branches" {
  run cmd_new --repo "$REMOTE" --branch nope --name wsx --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "main"
}

@test "cmd_new: empty repo without --init-empty errors naming the flag" {
  run cmd_new --repo "$EMPTY_REMOTE" --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--init-empty"
}

@test "cmd_new: empty repo with --init-empty seeds and proceeds" {
  run cmd_new --repo "$EMPTY_REMOTE" --name wsx --ide ssh --init-empty --yes
  [ "$status" -eq 0 ]
  git --git-dir "$EMPTY_REMOTE" rev-parse refs/heads/main   # branch now exists
  grep -q "up:" "$BATS_TEST_TMPDIR/calls"
}

@test "cmd_new: missing devcontainer without --seed-devcontainer warns but proceeds" {
  run cmd_new --repo "$REMOTE" --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "no devcontainer"
  echo "$output" | grep -q -- "--seed-devcontainer"
}

@test "cmd_new: without --yes, non-TTY fails closed before devpod up" {
  run cmd_new --repo "$REMOTE" --branch main --name wsx --ide ssh < /dev/null
  [ "$status" -eq 1 ]
  ! grep -q "up:" "$BATS_TEST_TMPDIR/calls" 2>/dev/null || false
}

@test "cmd_new: name colliding with catalog errors" {
  catalog_workspace_get() { [[ "$1" == "wsx" ]]; }
  run cmd_new --repo "$REMOTE" --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "already exists in catalog"
}

@test "cmd_new: name colliding with devpod store errors" {
  devpod() { case "$1" in list) printf '[{"id":"wsx"}]' ;; esac; }
  run cmd_new --repo "$REMOTE" --branch main --name wsx --ide ssh --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "already exists in DevPod"
}

@test "new --list-branches: prints resolved url then branches, rc 0" {
  run cmd_new --list-branches "$REMOTE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sed -n 1p)" = "$REMOTE" ]
  echo "$output" | sed -n 2p | grep -qx "main"
}

@test "new --list-branches: empty repo rc 3, url still printed" {
  run cmd_new --list-branches "$EMPTY_REMOTE"
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | sed -n 1p)" = "$EMPTY_REMOTE" ]
}

@test "new --list-branches: unreachable repo rc 2" {
  run cmd_new --list-branches "$BATS_TEST_TMPDIR/does-not-exist.git"
  [ "$status" -eq 2 ]
}

@test "new --check-devcontainer: missing devcontainer rc 1" {
  run cmd_new --check-devcontainer "$REMOTE" main
  [ "$status" -eq 1 ]
}

@test "new --check-devcontainer: present devcontainer rc 0" {
  run cmd_new --check-devcontainer "$DEVC_REMOTE" main
  [ "$status" -eq 0 ]
}

@test "new --check-devcontainer: unreachable repo rc 2" {
  run cmd_new --check-devcontainer "$BATS_TEST_TMPDIR/does-not-exist.git" main
  [ "$status" -eq 2 ]
}

# Regression for a bug where ui_progress's backgrounded marker subshell
# inherited the caller's stdout: when _fetch_remote_branches runs inside a
# `$(...)` command substitution, that fd IS the substitution's pipe, and the
# marker's `sleep 0.8` grandchild held the pipe's write end open until the
# sleep expired — so a fast, local ls-remote still took ~0.8s (paid twice
# when the HTTPS->SSH retry fires) instead of returning immediately.
@test "_fetch_remote_branches: returns promptly for a fast local remote (does not wait on the progress marker)" {
  local start end elapsed
  start=$EPOCHREALTIME
  _fetch_remote_branches "$REMOTE" >/dev/null
  end=$EPOCHREALTIME
  elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')
  awk -v e="$elapsed" 'BEGIN { exit !(e < 0.5) }'
}

# Companion regression: confirm the fix didn't neuter the marker itself —
# it must still reach stderr on a slow command.
@test "ui_progress: marker hint reaches stderr for a slow command" {
  local err
  err=$( { ui_progress "marker-test" sleep 1 1>/dev/null; } 2>&1 )
  echo "$err" | grep -q "marker-test"
}
