# Seed new repos with the blueprint devcontainer.json

**Date:** 2026-07-08
**Status:** approved

> **Correction (2026-07-14):** the assumption below that "DevPod reads root
> or `.devcontainer/`" is wrong — DevPod only probes
> `.devcontainer/devcontainer.json`, `.devcontainer.json`, and
> `.devcontainer/**/devcontainer.json` (pkg/devcontainer/config/parse.go).
> A root-level `devcontainer.json` is silently ignored and the container
> builds the bare fallback image. Fixed by
> `2026-07-14-seed-devcontainer-existing-branches.md`, which moves the seed
> to `.devcontainer/devcontainer.json` and extends seeding to non-empty
> repos.

## Problem

When `dvw new` is pointed at a freshly-created, commit-less repo, the wizard
offers to seed it so there is a branch to clone. Today that seed is a bare
`git commit --allow-empty -m "init"`. The very next step is `devpod up`,
which — with no `devcontainer.json` in the repo — falls back to DevPod's
auto-detected default container: no universal image, none of the
`.aicodingsetup`/`.claude`/etc. host mounts, no aiCodingBaseSetup harness
install. The user lands in a bare container until they add a devcontainer by
hand and force-rebuild.

## Design

Instead of an empty commit, seed the repo with the canonical blueprint
`devcontainer.json` from aiCodingBaseSetup, so the immediately-following
`devpod up` builds the right container on the first try.

### Fetch

- New helper `_fetch_blueprint_devcontainer <dest>` in `lib/wizard.sh`:
  `curl -fsSL --max-time 10` from
  `https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/devcontainer.json`
  — always the current blueprint, same source the blueprint's own
  `postStartCommand` already trusts. The URL lives in
  `DVW_BLUEPRINT_DEVCONTAINER_URL` (overridable) so tests can point it at a
  local `file://` fixture and never touch the network.
- Validation before use: file is non-empty and its first non-blank line
  starts with `{`. Rejects proxy/HTML error pages without being stricter
  than the devcontainer format (JSONC comments stay legal in future
  blueprint versions, so no hard `jq` parse).
- Missing `curl`, timeout, HTTP error, or failed validation → the helper
  returns non-zero.

### Seeding

`_init_empty_repo` gains the devcontainer step:

- Fetch into the throwaway temp dir before `git init`.
- Fetch OK → commit `devcontainer.json` at the repo root (matching where the
  blueprint keeps it; DevPod reads root or `.devcontainer/`) with message
  `init: blueprint devcontainer`.
- Fetch failed → fall back to today's empty commit (`init`) with a warning,
  rather than dead-ending the wizard. The repo still gets seeded; the
  container is just bare, exactly like today.
- The function reports which path it took via a global
  (`DVW_INIT_SEEDED_DEVCONTAINER`) so the wizard can word its status line;
  tests instead assert on the observable result (clone the bare remote,
  check the file).

### Wizard UX

- Confirm prompt becomes "Create an initial commit on 'main' (with the
  blueprint devcontainer.json) and push?" so the content push is no
  surprise.
- Success message names what was seeded; the fallback path warns that the
  blueprint fetch failed and a plain empty commit was pushed instead.

## Testing

`tests/bats/wizard.bats`, offline via `file://` URLs (real curl, no
network — per the repo rule that tests never hit real daemons/network):

- `_fetch_blueprint_devcontainer`: valid JSON fixture → success, content
  intact; missing file → failure; HTML error page → failure; empty file →
  failure.
- `_init_empty_repo` against a local bare repo: fetch OK → clone contains
  `devcontainer.json`, commit message `init: blueprint devcontainer`;
  fetch failing → branch still created, no devcontainer, empty-commit
  fallback.
- Existing `_init_empty_repo` tests get the override URL pointed at a
  missing file so they exercise the fallback instead of hitting GitHub.

## Explicitly not doing (YAGNI)

- No `templates/project` scaffolding in the initial commit —
  `scaffold-project` handles that in-container later.
- No interactive "empty vs devcontainer" choice — the fallback covers the
  degenerate case.
- No vendored copy of the devcontainer in dvw — single source of truth
  stays in aiCodingBaseSetup.
