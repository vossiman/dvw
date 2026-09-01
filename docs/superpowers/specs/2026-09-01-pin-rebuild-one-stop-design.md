# dvw pin-rebuild, one-stop pin update and rebuild

**Date:** 2026-09-01
**Status:** approved (brainstorm, architectural path)

## Problem

Rebuilding a workspace onto the current devbox image takes five manual steps
today, four of which are invisible, and skipping any one of them produces a
rebuild that *reports success while reinstalling the old image*.

The chain from source of truth to running container is:

1. **Blueprint**, `devcontainer.json` at tip-of-main of aiCodingBaseSetup
   (`DVW_BLUEPRINT_DEVCONTAINER_URL`, `lib/wizard.sh:93`). Owns the current
   image digest.
2. **Committed pin**, each workspace repo's
   `.devcontainer/devcontainer.json`, per branch.
3. **Source clone**, `~/.devpod/agent/contexts/default/workspaces/<id>/content`
   on vossisrv. A normal git checkout on some branch.
4. **Build**, `devpod up --recreate` reads the *working tree* of (3).
5. **Container**, the image that actually runs.

`dvw pin-sync` (`lib/pin.sh`) fixes (2) by PR. Three gaps remain:

- **Nothing pulls (3).** `grep 'git pull' lib/*.sh` hits only `dvw update`,
  operating on dvw's own repo. So merging the pin PR changes (2) and leaves
  (3) at the pre-merge commit; `dvw rebuild` then rebuilds from the stale
  working tree, exactly as if pin-sync had never run.
- **The PR may target a branch nothing builds from.** `_dvw_pin_state`
  (`lib/pin.sh:186`) reads `.branch` from the catalog record, which is the
  branch chosen at workspace *creation*. Anyone switching branches inside the
  workspace leaves (3) on a different branch, and the PR then patches a
  branch `devpod up` never reads.
- **No visibility.** Neither `dvw ls` nor the TUI compares the running image
  to the blueprint, so "am I on the current devbox?" has no answer short of
  running `pin-sync` and reading its output.

## Two staleness signals, deliberately distinct

| signal | comparison | cost | used for |
|---|---|---|---|
| **container stale** | running image vs blueprint | one docker inspect, already fetched | the UI badge |
| **repo pin stale** | committed pin vs blueprint | gh API / clone read | deciding a PR is needed |

They disagree in normal operation: right after a merge and pull the repo pin
is current while the container is still stale, and that is precisely the
state the badge must show. Collapsing them into one boolean would hide it.

## Solution

Three pieces: two catalog-service endpoints that expose and refresh the
source clone, one bash command that drives the whole loop with an assertion
after every step, and a badge plus menu entry in the UI.

### 1. Catalog service, own the source clone

The service already runs natively on vossisrv as the account that owns the
devpod agent directory (`deploy/dvw-catalog.service`), and
`lib/connect-resolver.sh` states the rule that provider state is reached
through the service, never through a client-side SSH fan-out. So the clone is
the service's to read.

```
GET  /v1/workspaces/{id}/source   -> WorkspaceSource
POST /v1/workspaces/{id}/source/pull -> WorkspaceSource
```

`WorkspaceSource`:

```jsonc
{
  "path": "/home/vossi/.devpod/agent/.../content",
  "present": true,          // false when the clone does not exist
  "branch": "feat/x",       // null when detached
  "head": "<sha>",
  "dirty": false,           // porcelain non-empty
  "remote": "https://github.com/owner/name",
  "committed_pin": "ghcr.io/...@sha256:...",  // .image from the WORKING TREE
  "detached": false
}
```

`committed_pin` is read from the working tree, not from GitHub: the working
tree is what the build reads, so it is the only copy whose value predicts the
outcome. Absent `.devcontainer/devcontainer.json` yields `null`.

`POST .../source/pull` runs `git -C <path> pull --ff-only` and returns the
refreshed `WorkspaceSource`. It **refuses** (409) when the clone is dirty or
detached, rather than pulling over someone's in-flight work, and reports
git's stderr verbatim on failure. It is the only mutating operation added and
it cannot fast-forward past a divergence.

Path resolution reuses the existing devpod agent-directory logic; the
directory is validated as a git work tree before either endpoint touches it.
The pull authenticates with whatever git credentials the service account
already holds on the box (the same ones devpod's own clone used); an auth
failure is not special-cased, it surfaces git's stderr like any other
failure.

### 2. Blueprint digest in the status payload

The service fetches the blueprint `devcontainer.json` and caches the parsed
image ref in memory with a short TTL (default 900s, `CATALOG_BLUEPRINT_TTL`).
One fetch serves every client and every row. On fetch failure the cached
value is served if present, otherwise `null`, never an error, never a
blocked response.

Added to the container status payload and to `ContainerInspect`:

- `blueprint_image`, the blueprint ref, or `null` when unknown.
- `image_digest`, the container's own `RepoDigests[0]` digest.
- `image_current`, `true` / `false`, or `null` when either side is unknown.

`image_current` compares the `sha256:` components only: `RepoDigests[0]`
has the form `repo@sha256:...` while the blueprint ref carries a registry
prefix, so whole-string comparison would false-negative on identical images.
A blueprint pinned to a tag rather than a digest cannot be compared and
yields `null`, never `false`.

`image_digest` is new because the existing `image` field
(`app/docker_inspect.py:363`) prefers a *tag* over the digest
(`(c.image.tags or [a.get("Image")])[0]`), and a tag cannot be compared
against a digest-pinned blueprint. `image` keeps its current meaning for
display; comparison uses `image_digest` only.

Tri-state, not boolean: "unknown" (offline, un-pinned repo, no container)
must not render as "outdated", or the badge cries wolf and gets ignored.

### 3. `_dvw_pin_state` resolves the live branch everywhere

`_dvw_pin_state` (used by `cmd_pin_sync` and `_dvw_pin_preflight`) gains the
same branch resolution as `pin-rebuild`: query
`GET /v1/workspaces/{id}/source` first and use the clone's live branch,
falling back to the catalog `.branch` (with the existing behaviour) when the
service is unreachable or the clone is absent. Without this, the standalone
`dvw pin-sync` and the rebuild preflight would keep opening PRs against the
creation-time branch, the exact wrong-branch failure this design removes.

### 4. `dvw pin-rebuild <id>`, the one-stop command

New file `lib/pin-rebuild.sh`, sourced alongside `lib/pin.sh`.

```
dvw pin-rebuild <workspace-id> [--dry-run] [--no-wait] [--timeout <s>]
```

Steps, each followed by an assertion, because every silent no-op in this
chain has already cost a rebuild:

1. **Resolve the build branch.** `GET /v1/workspaces/{id}/source`. Use
   `branch`. Detached or clone absent is a hard stop with the reason named.
   Service unreachable falls back to the catalog `.branch` with an explicit
   warning that the branch is unverified.
2. **Compare.** `committed_pin` (working tree) vs `blueprint_image`. Equal
   means no PR is needed; jump to step 6.
3. **Open PRs.** `_dvw_pin_open_pr` against the build branch, and a second
   against `main` when it differs, so the baseline is fixed once and future
   workspaces cut from `main` start current. The `main` PR is preceded by a
   `_dvw_repo_pin` check and skipped when `main` is already current or has
   no pin file, `_dvw_pin_open_pr` treats a byte-identical rewrite as an
   error, so opening it blindly would report a spurious failure. Existing
   open PRs are reported, not duplicated (today's behaviour). Print both
   URLs.
4. **Wait for the merge, verified.** Poll
   `gh pr view <url> --json state,mergedAt` every 10s. Enter forces an
   immediate re-check; Ctrl-C aborts cleanly leaving the PRs open. Only the
   build-branch PR gates the rebuild, a `main` PR left unmerged is reported
   and does not block. `--no-wait` stops after step 3 and prints the URLs.
   `--timeout` (default 1800s) bounds the poll.
   Merge state comes from `gh`, never from the user's say-so: "I merged it"
   is the one input that is wrong exactly when it matters.
5. **Pull.** `POST /v1/workspaces/{id}/source/pull`. A 409 (dirty/detached)
   is a hard stop naming the file or the detached HEAD.
6. **Assert the pin.** Re-read `committed_pin`. If it still differs from
   `blueprint_image`, stop before rebuilding and say which of pull / PR / base
   branch did not do what it claimed. **This is the assertion that would have
   caught the original bug.**
7. **Rebuild.** `devpod up --recreate --ide <ide>`, reusing `cmd_recreate`'s
   IDE resolution and its `_dvw_ensure_ssh_alias` follow-up.
8. **Assert the container.** Re-inspect; compare `image_digest` to
   `blueprint_image`. Report `✓ running <digest>` or a loud failure. A
   rebuild that ends on the old image must exit non-zero.

`--dry-run` honours `DVW_DRY_RUN` as `pin-sync` does: prints every step,
opens nothing, pulls nothing, rebuilds nothing.

Exit codes: `0` current (whether or not work was done), `1` a step failed,
`2` aborted by the user at the merge gate.

### 5. UI

- **TUI:** a `⬆` badge (accent, from `render.py`'s palette) in the state cell
  when `image_current` is `false`. `null` renders nothing. Menu gains
  `u  update pin & rebuild`, dispatched through `actions.py` as
  `[dvw, "pin-rebuild", id]` with the **suspend** execution style, because
  the merge gate needs the real terminal.
- **`dvw ls`:** same badge in the existing status column.
- **`cmd_recreate`:** the existing `_dvw_pin_preflight` offer stays, but now
  points at `dvw pin-rebuild <id>` instead of telling the user to re-run
  `dvw rebuild` themselves after merging.

## Rejected

- **Write the blueprint pin straight into the source clone's working tree and
  rebuild, treating the PR as bookkeeping.** Fastest possible loop, but the
  container then runs an image the repo does not record, the failure mode
  `lib/pin.sh`'s header comment exists to prevent. The repo stays the source
  of truth for what a workspace runs.
- **Bash sshs to vossisrv and runs git in the clone directly.** Ships without
  a service deploy, but hardcodes the devpod agent path client-side and
  re-adds the SSH fan-out `lib/connect-resolver.sh` explicitly removed.
- **Trust catalog `.branch`.** It records the branch at creation, which is
  wrong for exactly the workspaces people actually work in.
- **A cron/bot that opens pin PRs.** Rejected 2026-08-20 (PR noise); nothing
  here changes that. `pin-rebuild` runs when asked.

## Testing

- **Service:** `WorkspaceSource` over a temp git repo, clean, dirty,
  detached, absent clone, missing `devcontainer.json`. Pull: fast-forward,
  refuses dirty, refuses detached, surfaces git stderr. Blueprint cache: hit,
  miss, TTL expiry, fetch failure serving a stale value, fetch failure with
  an empty cache yielding `null`.
- **Bash:** the step chain against a stubbed catalog and a stubbed `gh`.
  Covers pin already current (no PR), stale then merged then pulled then
  current, pull refused, and the step-6 assertion firing when the pull
  silently no-ops. `DVW_DRY_RUN=1` opens and mutates nothing.
- **TUI:** `image_current` `true` / `false` / `null` render as no badge /
  `⬆` / no badge; the menu entry builds the expected argv.
- **Manual, on one real workspace:** confirm the badge appears, run the menu
  action end to end, confirm step 8 reports the new digest.
