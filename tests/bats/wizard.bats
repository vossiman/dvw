#!/usr/bin/env bats
#
# Tests for lib/wizard.sh's standalone helpers (the interactive flow itself
# is the native Textual TUI wizard, covered by tui/tests/*). Background:
# DEVPOD_NAME_MAX exists because `devpod up` rejects "workspace name cannot
# be longer than N characters" — a bug surfaced 2026-05-31 when a 49-char
# auto-suggested name (from a long branch like
# `design/dvw-extract-and-multi-agent`) blew through DevPod's 48-char cap.
# (The truncation helper itself, `_truncate_for_devpod`, was removed
# 2026-08-11 — cmd_new does the length check inline and DEVPOD_NAME_MAX is
# the part still worth pinning down.)

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

@test "_sanitize_ws_name: lowercases + replaces non-alnum-dash + trims" {
  # Pre-existing helper — protect it from regression while we're in here.
  run _sanitize_ws_name "Foo/Bar @baz.git"
  [ "$status" -eq 0 ]
  [ "$output" = "foo-bar-baz-git" ]
}

# _parse_remote_branches: the only non-interactive, non-network part of the branch
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

@test "_init_empty_repo: seeds .devcontainer/devcontainer.json when the blueprint fetch works" {
  # DevPod only looks at .devcontainer/devcontainer.json, .devcontainer.json,
  # and .devcontainer/**/devcontainer.json (pkg/devcontainer/config/parse.go)
  # — a root-level devcontainer.json is silently ignored and the container
  # comes up on the bare fallback image (2026-07-14, obsidian-selfhost).
  local bare="$BATS_TEST_TMPDIR/remote-seeded.git"
  git init -q --bare -b main "$bare"
  _use_devcontainer_fixture

  run _init_empty_repo "$bare" main
  [ "$status" -eq 0 ]

  local clone="$BATS_TEST_TMPDIR/clone-seeded"
  git clone -q "$bare" "$clone"
  [ -f "$clone/.devcontainer/devcontainer.json" ]
  [ ! -e "$clone/devcontainer.json" ]
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

# _branch_has_devcontainer / _seed_devcontainer_on_branch: extend the
# blueprint seeding to repos that already have commits but no devcontainer
# (2026-07-14: obsidian-selfhost came up on DevPod's bare ubuntu fallback —
# no tmux, no toolchain, no git identity). Detection mirrors DevPod's own
# lookup paths; seeding commits with the host's git identity and pushes so
# the `devpod up` that follows clones a repo that builds the real harness.

# Create a bare "remote" at $1 whose main branch carries the files named by
# the remaining args (each created as a stub). Local-only, no network.
_make_remote_with_files() {
  local bare="$1"; shift
  git init -q --bare -b main "$bare"
  local work="$bare.work"
  git clone -q "$bare" "$work" 2>/dev/null
  local f
  for f in "$@"; do
    mkdir -p "$work/$(dirname "$f")"
    printf '{"stub": true}\n' > "$work/$f"
  done
  ( cd "$work" \
      && git add -A \
      && git -c user.name=fixture -c user.email=fixture@test commit -q --allow-empty -m "fixture" \
      && git push -q origin main )
  rm -rf "$work"
}

@test "_branch_has_devcontainer: 0 for .devcontainer/devcontainer.json" {
  local bare="$BATS_TEST_TMPDIR/has-dir.git"
  _make_remote_with_files "$bare" README.md .devcontainer/devcontainer.json
  run _branch_has_devcontainer "$bare" main
  [ "$status" -eq 0 ]
}

@test "_branch_has_devcontainer: 0 for root .devcontainer.json" {
  local bare="$BATS_TEST_TMPDIR/has-dot.git"
  _make_remote_with_files "$bare" README.md .devcontainer.json
  run _branch_has_devcontainer "$bare" main
  [ "$status" -eq 0 ]
}

@test "_branch_has_devcontainer: 0 for nested .devcontainer/<sub>/devcontainer.json" {
  local bare="$BATS_TEST_TMPDIR/has-nested.git"
  _make_remote_with_files "$bare" README.md .devcontainer/gpu/devcontainer.json
  run _branch_has_devcontainer "$bare" main
  [ "$status" -eq 0 ]
}

@test "_branch_has_devcontainer: 1 when the branch has no devcontainer" {
  local bare="$BATS_TEST_TMPDIR/has-none.git"
  _make_remote_with_files "$bare" README.md src/app.py
  run _branch_has_devcontainer "$bare" main
  [ "$status" -eq 1 ]
}

@test "_branch_has_devcontainer: 1 for root devcontainer.json (devpod ignores it)" {
  local bare="$BATS_TEST_TMPDIR/has-root-only.git"
  _make_remote_with_files "$bare" README.md devcontainer.json
  run _branch_has_devcontainer "$bare" main
  [ "$status" -eq 1 ]
}

@test "_branch_has_devcontainer: 2 when the repo is unreachable" {
  run _branch_has_devcontainer "$BATS_TEST_TMPDIR/does-not-exist.git" main
  [ "$status" -eq 2 ]
}

@test "_seed_devcontainer_on_branch: commits + pushes the blueprint devcontainer" {
  local bare="$BATS_TEST_TMPDIR/seed-target.git"
  _make_remote_with_files "$bare" README.md src/app.py
  _use_devcontainer_fixture

  run _seed_devcontainer_on_branch "$bare" main
  [ "$status" -eq 0 ]

  local clone="$BATS_TEST_TMPDIR/seed-clone"
  git clone -q "$bare" "$clone"
  cmp -s "$DVW_TEST_FIXTURE" "$clone/.devcontainer/devcontainer.json"
  # Existing history and files must survive — this is a commit on top, not
  # a rewrite.
  [ -f "$clone/README.md" ]
  [ -f "$clone/src/app.py" ]
  run git -C "$clone" rev-list --count main
  [ "$output" = "2" ]
}

@test "_seed_devcontainer_on_branch: seed commit uses the host git identity" {
  local bare="$BATS_TEST_TMPDIR/seed-ident.git"
  _make_remote_with_files "$bare" README.md
  _use_devcontainer_fixture
  # Simulate the host's global git identity without touching the real one.
  local cfg="$BATS_TEST_TMPDIR/gitconfig"
  git config --file "$cfg" user.name "Host User"
  git config --file "$cfg" user.email "host@example.com"

  GIT_CONFIG_GLOBAL="$cfg" GIT_CONFIG_SYSTEM=/dev/null \
    run _seed_devcontainer_on_branch "$bare" main
  [ "$status" -eq 0 ]

  run git --git-dir "$bare" log -1 --format='%an <%ae>' main
  [ "$output" = "Host User <host@example.com>" ]
}

@test "_seed_devcontainer_on_branch: falls back to a generic identity when unset" {
  local bare="$BATS_TEST_TMPDIR/seed-noident.git"
  _make_remote_with_files "$bare" README.md
  _use_devcontainer_fixture

  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    run _seed_devcontainer_on_branch "$bare" main
  [ "$status" -eq 0 ]

  run git --git-dir "$bare" log -1 --format='%an <%ae>' main
  [ "$output" = "dvw <dvw@localhost>" ]
}

@test "_seed_devcontainer_on_branch: fails without touching the remote when the fetch fails" {
  # setup() points the blueprint URL at a missing file.
  local bare="$BATS_TEST_TMPDIR/seed-nofetch.git"
  _make_remote_with_files "$bare" README.md

  run _seed_devcontainer_on_branch "$bare" main
  [ "$status" -ne 0 ]

  run git --git-dir "$bare" rev-list --count main
  [ "$output" = "1" ]
}

@test "_seed_devcontainer_on_branch: fails when the remote is unreachable" {
  _use_devcontainer_fixture
  run _seed_devcontainer_on_branch "$BATS_TEST_TMPDIR/does-not-exist.git" main
  [ "$status" -ne 0 ]
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
