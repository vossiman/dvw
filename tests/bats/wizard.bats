#!/usr/bin/env bats
#
# Tests for lib/wizard.sh's standalone helpers (the interactive flow itself
# is gum-driven and tested manually). Focused on the name-length validator
# that prevents `devpod up` rejecting "workspace name cannot be longer than
# N characters" — a bug surfaced 2026-05-31 when a 49-char auto-suggested
# name (from a long branch like `design/dvw-extract-and-multi-agent`)
# blew through DevPod's 48-char cap.

setup() {
  # wizard.sh's helpers are pure shell — sourcing has no side effects.
  source "$DVW_ROOT/lib/wizard.sh"
}

@test "DEVPOD_NAME_MAX matches DevPod's documented limit" {
  [ "$DEVPOD_NAME_MAX" -eq 48 ]
}

@test "_truncate_for_devpod: name shorter than max passes through unchanged" {
  run _truncate_for_devpod "short-name"
  [ "$status" -eq 0 ]
  [ "$output" = "short-name" ]
}

@test "_truncate_for_devpod: 48-char name passes through unchanged" {
  # Exactly 48 'a' characters — the boundary case.
  local name="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "${#name}" -eq 48 ]
  run _truncate_for_devpod "$name"
  [ "$status" -eq 0 ]
  [ "$output" = "$name" ]
}

@test "_truncate_for_devpod: name longer than max truncates to <= max" {
  # The verification-triggering input from 2026-05-31: 49 chars, 1 over.
  run _truncate_for_devpod "devmachine-git-design-dvw-extract-and-multi-agent"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 48 ]
}

@test "_truncate_for_devpod: result is a clean identifier (no trailing dash)" {
  # 'aaaa...' (47 chars) + '-' + 'rest' → truncated to 48 lands on the dash,
  # which must be trimmed for the result to be a valid workspace ID.
  local input="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-rest"
  run _truncate_for_devpod "$input"
  [ "${output: -1}" != "-" ]
}

@test "_truncate_for_devpod: respects custom max when given as second arg" {
  run _truncate_for_devpod "this-is-thirty-characters-foo" 10
  [ "$status" -eq 0 ]
  [ "${#output}" -le 10 ]
}

@test "_truncate_for_devpod: empty input echoes empty" {
  run _truncate_for_devpod ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_truncate_for_devpod is idempotent on already-truncated names" {
  # Truncating twice yields the same result as truncating once.
  local input="devmachine-git-design-dvw-extract-and-multi-agent"
  run _truncate_for_devpod "$input"
  local once="$output"
  run _truncate_for_devpod "$once"
  [ "$output" = "$once" ]
}

@test "_sanitize_ws_name: lowercases + replaces non-alnum-dash + trims" {
  # Pre-existing helper — protect it from regression while we're in here.
  run _sanitize_ws_name "Foo/Bar @baz.git"
  [ "$status" -eq 0 ]
  [ "$output" = "foo-bar-baz-git" ]
}

# _parse_remote_branches: the only non-gum, non-network part of the branch
# step (added 2026-06-01 so the wizard offers a picker of branches that
# actually exist on the remote, instead of pre-filling a stale catalog
# default that `devpod up` later rejects with "exit status 128").

@test "_parse_remote_branches: strips sha + refs/heads/ and sorts" {
  run _parse_remote_branches <<'EOF'
9d42395eef275d794db7a37c3f40305ff3485831	refs/heads/main
3b6b659fc101077afc11c2d4e6b31d69508c0e2b	refs/heads/design/foo
abc123def456abc123def456abc123def456abcd	refs/heads/feature/bar
EOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "design/foo" ]
  [ "${lines[1]}" = "feature/bar" ]
  [ "${lines[2]}" = "main" ]
}

@test "_parse_remote_branches: empty input yields no output" {
  run _parse_remote_branches <<<""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_parse_remote_branches: keeps slashes in branch names intact" {
  # refs/heads/ must only be stripped once, at the start — a branch named
  # like 'release/refs/heads-thing' should not be mangled.
  run _parse_remote_branches <<'EOF'
0000000000000000000000000000000000000000	refs/heads/release/v1.2.3
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "release/v1.2.3" ]
}

# _parse_devpod_ids: extracts workspace IDs from `devpod list --output json`.
# Added 2026-06-01 after the wizard let a name that already existed in DevPod
# (but not the catalog) through its duplicate check — `devpod up --id <name>`
# then silently reused that workspace's pinned branch and ignored the branch
# the user picked, cloning a stale branch that failed with "exit status 128".

@test "_parse_devpod_ids: extracts ids from devpod list json" {
  run _parse_devpod_ids <<'EOF'
[{"id":"devmachine","source":{"gitBranch":"design/x"}},{"id":"financepdfs-git-main"}]
EOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "devmachine" ]
  [ "${lines[1]}" = "financepdfs-git-main" ]
}

@test "_parse_devpod_ids: empty array yields no output" {
  run _parse_devpod_ids <<<'[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_parse_devpod_ids: empty input yields no output" {
  run _parse_devpod_ids <<<''
  [ -z "$output" ]
}
