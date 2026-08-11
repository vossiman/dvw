#!/usr/bin/env bats
#
# `dvw new --list-branches` / `--check-devcontainer` are the TUI wizard's
# plumbing: STDOUT is a machine-read contract (line 1 = the resolved repo
# URL) and the exit code carries meaning (0 branches / 2 unreachable /
# 3 empty / 1 no devcontainer).
#
# Regression (final review of feat/degum, 2026-08-11): they used to run
# through main()'s full pre-dispatch, so the update nudge (which printfs to
# STDOUT when the checkout is behind main) and the three ui_progress
# pre-flights could prepend garbage to line 1 — and a pre-flight failure
# (`catalog_init_if_missing || exit 1`) could masquerade as rc 1, i.e.
# "devcontainer missing", triggering a bogus seed offer. main() now
# dispatches both flags before any of that.
#
# Harness: sourced-main, same as bare-dvw.bats (main() only auto-runs when
# the script is executed directly).

setup() {
  source "$DVW_ROOT/dvw"

  # Pre-dispatch machinery, stubbed LOUDLY: if the early dispatch ever
  # regresses, this text lands on stdout / these markers get written.
  dvw_update_refresh_if_stale() { printf 'NUDGE-REFRESH\n'; }
  dvw_update_maybe_nudge() { printf '⬆ dvw is 3 behind main — run: dvw update\n'; }
  catalog_init_if_missing() {
    touch "$BATS_TEST_TMPDIR/preflight-ran"
    # Slow enough that ui_progress's 0.8s marker fires (on stderr) — the
    # other half of the pollution this dispatch avoids.
    sleep 1
  }
  ssh_sync_refresh() { touch "$BATS_TEST_TMPDIR/preflight-ran"; }
  wsl_bridge_refresh() { touch "$BATS_TEST_TMPDIR/preflight-ran"; }

  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$BATS_TEST_TMPDIR/absent.json"

  # A "remote" with one commit on main, no devcontainer.
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  (
    tmp=$(mktemp -d) && cd "$tmp" && git init -q -b main \
      && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
      && git remote add origin "$REMOTE" && git push -q origin main
  )
  EMPTY_REMOTE="$BATS_TEST_TMPDIR/empty.git"
  git init -q --bare "$EMPTY_REMOTE"
  DEVC_REMOTE="$BATS_TEST_TMPDIR/devc.git"
  git init -q --bare "$DEVC_REMOTE"
  (
    tmp=$(mktemp -d) && cd "$tmp" && git init -q -b main \
      && mkdir -p .devcontainer && printf '{"stub": true}\n' > .devcontainer/devcontainer.json \
      && git add -A \
      && git -c user.name=t -c user.email=t@t commit -q -m init \
      && git remote add origin "$DEVC_REMOTE" && git push -q origin main
  )
}

# Run main capturing STDOUT ONLY — exactly what the TUI's split capture
# (actions.run_captured_split) sees. bats' `run` would merge stderr in.
_stdout_only() { main "$@" 2>/dev/null; }

@test "main new --list-branches: stdout line 1 is the resolved url, no nudge" {
  run _stdout_only new --list-branches "$REMOTE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REMOTE" ]
  [ "${lines[1]}" = "main" ]
  ! echo "$output" | grep -q 'behind main'
  ! echo "$output" | grep -q 'NUDGE-REFRESH'
  ! echo "$output" | grep -q '›'
}

@test "main new --list-branches: pre-flights do not run at all" {
  run _stdout_only new --list-branches "$REMOTE"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/preflight-ran" ]
}

@test "main new --list-branches: rc 3 for an empty repo, url still line 1" {
  run _stdout_only new --list-branches "$EMPTY_REMOTE"
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "$EMPTY_REMOTE" ]
}

@test "main new --list-branches: rc 2 for an unreachable repo" {
  run _stdout_only new --list-branches "$BATS_TEST_TMPDIR/does-not-exist.git"
  [ "$status" -eq 2 ]
}

@test "main new --check-devcontainer: rc 1 means missing, not a pre-flight failure" {
  run _stdout_only new --check-devcontainer "$REMOTE" main
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/preflight-ran" ]
}

@test "main new --check-devcontainer: rc 0 when present" {
  run _stdout_only new --check-devcontainer "$DEVC_REMOTE" main
  [ "$status" -eq 0 ]
}

@test "main new with real flags still goes through the pre-flights" {
  # The early dispatch must be narrow: only the two plumbing flags.
  cmd_new() { echo "cmd_new:$*"; }
  run main new --repo R --branch b --name n --ide ssh --yes
  [ -e "$BATS_TEST_TMPDIR/preflight-ran" ]
  echo "$output" | grep -q 'cmd_new:--repo R'
  echo "$output" | grep -q 'behind main'
}
