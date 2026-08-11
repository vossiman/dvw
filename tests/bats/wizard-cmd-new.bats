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
