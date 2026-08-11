#!/usr/bin/env bats
#
# cmd_rm --yes and ui_confirm-based prompts (gum removed 2026-08-11).
# Sources dvw like dispatch.bats; stubs catalog + probe state.

setup() {
  source "$DVW_ROOT/dvw"
  # Catalog stubs: workspace "w1" exists; removal helpers are no-ops that
  # record invocation.
  catalog_workspace_get() { [[ "$1" == "w1" ]]; }
  catalog_workspace_remove() { echo "removed:$1" >> "$BATS_TEST_TMPDIR/calls"; }
  _dvw_load_running_ids() { :; }
  _dvw_run_or_print() { echo "run:$*" >> "$BATS_TEST_TMPDIR/calls"; }
  _dvw_remove_ssh_alias() { echo "ssh-alias-removed:$1" >> "$BATS_TEST_TMPDIR/calls"; }
  DVW_RUNNING_IDS="w1"     # w1 counts as running -> confirm required
  # devpod present-and-knows-w1 so the running-confirm path is taken.
  devpod() {
    case "$1" in
      list) printf '[{"id":"w1"}]' ;;
      delete) echo "deleted:$2" >> "$BATS_TEST_TMPDIR/calls" ;;
    esac
  }
}

@test "cmd_rm --yes skips the running-workspace confirm" {
  run cmd_rm w1 --yes < /dev/null
  [ "$status" -eq 0 ]
  ! grep -q "assuming no" <<<"$output"
}

@test "cmd_rm on a running workspace without --yes fails closed non-TTY" {
  unset DVW_ASSUME_TTY
  run cmd_rm w1 < /dev/null
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "non-interactive"
}

@test "cmd_rm answers-no aborts" {
  export DVW_ASSUME_TTY=1
  run cmd_rm w1 <<< "n"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "aborted"
}

@test "cmd_rm answers-yes proceeds" {
  export DVW_ASSUME_TTY=1
  run cmd_rm w1 <<< "y"
  [ "$status" -eq 0 ]
}

@test "cmd_rm --yes skips the catalog-only confirm" {
  devpod() {
    case "$1" in
      list) printf '[]' ;;
    esac
  }
  run cmd_rm w1 --yes < /dev/null
  [ "$status" -eq 0 ]
  ! grep -q "assuming no" <<<"$output"
}

@test "cmd_rm catalog-only answers-no aborts" {
  devpod() {
    case "$1" in
      list) printf '[]' ;;
    esac
  }
  export DVW_ASSUME_TTY=1
  run cmd_rm w1 <<< "n"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "aborted"
}
