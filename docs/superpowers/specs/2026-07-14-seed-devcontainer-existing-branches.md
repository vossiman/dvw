# Seed devcontainer onto existing branches (and fix the seed path)

**Date:** 2026-07-14
**Status:** implemented

## Problem

Two gaps surfaced when `dvw new` created a workspace for
`obsidian-selfhost` (a repo with commits but no devcontainer):

1. **Existing repos are never checked.** The 2026-07-08 seeding only covers
   commit-less repos; a repo with history but no devcontainer sails straight
   into `devpod up`, which falls back to the bare
   `mcr.microsoft.com/devcontainers/base:ubuntu` image — no tmux, no
   toolchain, no git identity, none of the blueprint mounts.
2. **The empty-repo seed targeted the wrong path.** It committed the
   blueprint file at the repo root as `devcontainer.json`, but DevPod only
   probes `.devcontainer/devcontainer.json`, `.devcontainer.json`, and
   `.devcontainer/**/devcontainer.json` (pkg/devcontainer/config/parse.go).
   Root-level files are silently ignored, so even "seeded" empty repos came
   up bare.

## Design

All in `lib/wizard.sh`; blueprint fetch and identity policy reuse the
existing helpers/conventions.

- `_init_empty_repo` now writes the blueprint to
  `.devcontainer/devcontainer.json` (path fix).
- New `_branch_has_devcontainer <repo> <branch>` — 0 present / 1 missing /
  2 couldn't inspect. Probes with a bare, shallow, blobless
  (`--filter=blob:none`) clone and `git ls-tree`, matching exactly the
  paths DevPod probes. Tree objects only, so cheap even for blob-heavy
  repos (Obsidian vaults being the use case).
- New `_seed_devcontainer_on_branch <repo> <branch>` — fetches the
  blueprint, commits it as `.devcontainer/devcontainer.json` on the branch
  with the **host's git identity** (`git config user.*`, generic
  `dvw <dvw@localhost>` fallback — same policy as `_init_empty_repo`), and
  pushes. Fails without touching the remote when the fetch fails.
  Implementation invariant: the clone is `--no-checkout`, which leaves the
  index EMPTY — `git read-tree HEAD` first, or the seed commit's tree would
  contain only the devcontainer and wipe the branch (caught by the bats
  test before it ever ran against a real repo).
- Wizard step 2b: after the branch pick (skipped when `_init_empty_repo`
  just ran), detect → warn → `gum confirm` → seed → continue to
  `devpod up`. Seeding happens before the container is ever built, so the
  first build is already the harness container — no rebuild step needed.
  Declining or a failed seed continues with a loud "expect a bare
  container" warning; an uninspectable branch warns and continues.

## Testing

`tests/bats/wizard.bats`, offline (local bare remotes, `file://` blueprint
fixtures): detection across all three DevPod paths plus the
root-`devcontainer.json`-doesn't-count case; seeding preserves existing
history/files, uses the host identity (via `GIT_CONFIG_GLOBAL` isolation),
falls back to the generic identity, and leaves the remote untouched on
fetch failure. The interactive step 2b follows the file's convention of
manual testing for gum-driven flow.

## Explicitly not doing (YAGNI)

- No auto-seed without a confirm — it pushes a commit to the user's repo.
- No handling for already-created bare workspaces — seed the repo, then
  `dvw recreate <ws>`.
- No devcontainer drift detection for already-seeded repos (blueprint mount
  changes don't propagate) — tracked as a possible aiCodingBaseSetup
  `on-start.sh` warning, out of dvw's scope.
