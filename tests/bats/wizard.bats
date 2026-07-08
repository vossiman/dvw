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
  # Point the blueprint devcontainer fetch at a file:// URL that doesn't
  # exist: tests must never reach real GitHub, and _init_empty_repo tests
  # that don't care about seeding should exercise the empty-commit fallback.
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$BATS_TEST_TMPDIR/absent-devcontainer.json"
}

# Write a minimal valid devcontainer.json fixture and point the fetch URL at
# it. Sets DVW_TEST_FIXTURE to the fixture path. (Must NOT be called in a
# $(...) substitution — the URL export would die with the subshell.)
_use_devcontainer_fixture() {
  DVW_TEST_FIXTURE="$BATS_TEST_TMPDIR/blueprint-devcontainer.json"
  printf '{\n  "image": "mcr.microsoft.com/devcontainers/universal:6"\n}\n' > "$DVW_TEST_FIXTURE"
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$DVW_TEST_FIXTURE"
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

# _github_https_to_ssh: rewrites an HTTPS github.com URL to its SSH form so the
# wizard can fall back to ssh-agent auth (added 2026-06-16 after `dvw new` with
# an https://github.com/... URL aborted with the opaque "exited 128" — git
# ls-remote over HTTPS has no credential helper in the devbox).

@test "_github_https_to_ssh: rewrites https github url to ssh" {
  run _github_https_to_ssh "https://github.com/vossiman/hackertyper.git"
  [ "$status" -eq 0 ]
  [ "$output" = "git@github.com:vossiman/hackertyper.git" ]
}

@test "_github_https_to_ssh: adds missing .git suffix" {
  run _github_https_to_ssh "https://github.com/vossiman/hackertyper"
  [ "$output" = "git@github.com:vossiman/hackertyper.git" ]
}

@test "_github_https_to_ssh: strips embedded token/userinfo" {
  run _github_https_to_ssh "https://ghp_secret@github.com/vossiman/hackertyper.git"
  [ "$output" = "git@github.com:vossiman/hackertyper.git" ]
}

@test "_github_https_to_ssh: leaves an already-ssh url unchanged" {
  run _github_https_to_ssh "git@github.com:vossiman/hackertyper.git"
  [ "$output" = "git@github.com:vossiman/hackertyper.git" ]
}

@test "_github_https_to_ssh: idempotent" {
  run _github_https_to_ssh "https://github.com/vossiman/hackertyper.git"
  local once="$output"
  run _github_https_to_ssh "$once"
  [ "$output" = "$once" ]
}

@test "_github_https_to_ssh: leaves non-github https hosts unchanged" {
  # github.com only — other hosts may legitimately use HTTPS.
  run _github_https_to_ssh "https://gitlab.com/group/proj.git"
  [ "$output" = "https://gitlab.com/group/proj.git" ]
}

# _init_empty_repo: seeds an empty remote with an initial commit so `dvw new`
# can proceed (added 2026-06-16 after a freshly-created, commit-less repo made
# the wizard dead-end on "couldn't list branches"). Tested against a local bare
# repo — exercises the real init+commit+push path with no network.

@test "_init_empty_repo: seeds an empty bare repo with a main branch" {
  local bare="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare -b main "$bare"
  # Precondition: genuinely empty.
  run git ls-remote --heads "$bare"
  [ -z "$output" ]

  run _init_empty_repo "$bare" main
  [ "$status" -eq 0 ]

  run git ls-remote --heads "$bare"
  [[ "$output" == *"refs/heads/main"* ]]
}

@test "_init_empty_repo: defaults to main when no branch given" {
  local bare="$BATS_TEST_TMPDIR/remote2.git"
  git init -q --bare -b main "$bare"
  run _init_empty_repo "$bare"
  [ "$status" -eq 0 ]
  run git ls-remote --heads "$bare"
  [[ "$output" == *"refs/heads/main"* ]]
}

@test "_init_empty_repo: fails (non-zero) when the remote is unreachable" {
  run _init_empty_repo "$BATS_TEST_TMPDIR/does-not-exist.git" main
  [ "$status" -ne 0 ]
}

# _fetch_blueprint_devcontainer: pulls the canonical devcontainer.json from
# the aiCodingBaseSetup blueprint so _init_empty_repo can seed new repos with
# a working container config instead of a bare empty commit (2026-07-08).
# file:// URLs keep these offline.

@test "_fetch_blueprint_devcontainer: fetches a valid fixture intact" {
  local dest="$BATS_TEST_TMPDIR/fetched.json"
  _use_devcontainer_fixture
  run _fetch_blueprint_devcontainer "$dest"
  [ "$status" -eq 0 ]
  cmp -s "$DVW_TEST_FIXTURE" "$dest"
}

@test "_fetch_blueprint_devcontainer: fails when the source is unreachable" {
  # setup() already points the URL at a missing file.
  run _fetch_blueprint_devcontainer "$BATS_TEST_TMPDIR/fetched.json"
  [ "$status" -ne 0 ]
}

@test "_fetch_blueprint_devcontainer: rejects an HTML error page" {
  local page="$BATS_TEST_TMPDIR/error.html"
  printf '<html><body>503 Service Unavailable</body></html>\n' > "$page"
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$page"
  run _fetch_blueprint_devcontainer "$BATS_TEST_TMPDIR/fetched.json"
  [ "$status" -ne 0 ]
}

@test "_fetch_blueprint_devcontainer: rejects an empty response" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  : > "$empty"
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$empty"
  run _fetch_blueprint_devcontainer "$BATS_TEST_TMPDIR/fetched.json"
  [ "$status" -ne 0 ]
}

@test "_fetch_blueprint_devcontainer: tolerates leading blank lines before {" {
  # The validator wants the first non-blank line to open a JSON object —
  # leading whitespace must not trip it.
  local fixture="$BATS_TEST_TMPDIR/padded.json"
  printf '\n\n  {\n  "image": "x"\n}\n' > "$fixture"
  export DVW_BLUEPRINT_DEVCONTAINER_URL="file://$fixture"
  run _fetch_blueprint_devcontainer "$BATS_TEST_TMPDIR/fetched.json"
  [ "$status" -eq 0 ]
}

@test "_init_empty_repo: seeds devcontainer.json when the blueprint fetch works" {
  local bare="$BATS_TEST_TMPDIR/remote-seeded.git"
  git init -q --bare -b main "$bare"
  _use_devcontainer_fixture

  run _init_empty_repo "$bare" main
  [ "$status" -eq 0 ]

  local clone="$BATS_TEST_TMPDIR/clone-seeded"
  git clone -q "$bare" "$clone"
  [ -f "$clone/devcontainer.json" ]
  run git -C "$clone" log -1 --format=%s
  [ "$output" = "init: blueprint devcontainer" ]
}

@test "_init_empty_repo: falls back to an empty commit when the fetch fails" {
  # setup() points the URL at a missing file → fetch fails → old behavior.
  local bare="$BATS_TEST_TMPDIR/remote-fallback.git"
  git init -q --bare -b main "$bare"

  run _init_empty_repo "$bare" main
  [ "$status" -eq 0 ]

  local clone="$BATS_TEST_TMPDIR/clone-fallback"
  git clone -q "$bare" "$clone"
  [ ! -e "$clone/devcontainer.json" ]
  run git -C "$clone" log -1 --format=%s
  [ "$output" = "init" ]
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
