# `dvw update` follows superproject pins

## Problem

When the dvw checkout is a git submodule of a parent repo (devMachine pins it at
`devpod/dvw`), `dvw update` refuses outright:

```
✗ dvw is a git submodule of /home/vossi/local_dev/devMachine — refusing `dvw update`
  bump the parent submodule pointer instead (e.g. `bash scripts/update-submodules.sh && git push`)
```

The refusal is correct about one thing — pulling dvw's own `main` in place would
desync it from the pin the parent declares. But it leaves the user with nothing:
the command they reached for does no work, and the suggested alternative
(`update-submodules.sh`) moves the pin *forward* and creates a commit to push,
which is maintainer work, not "get me current".

The user-facing intent of `dvw update` is "put me on the newest released
tooling". Under a superproject, the newest released tooling *is* the parent's
`main` and the commits it pins.

## Goal

In superproject mode, `dvw update` follows the pins:

1. fast-forward the parent to its `origin/main`,
2. check out every submodule at the commit the parent pins,
3. re-run the dvw installer.

No commits are created; nothing needs pushing. Standalone (non-submodule)
behaviour is unchanged.

## Non-goals

- **Moving the pins forward.** Advancing submodules to their own `main` tips and
  committing the bump stays the parent repo's job (`update-submodules.sh`,
  devMachine's end-of-session convention). `dvw update` never commits and never
  pushes.
- No `--bump` flag, no stashing, no auto-checkout of branches, no recursive
  installer runs for other submodules (aicoding is a blueprint source on the
  host; it has no host-side install step).

## Design

### Detection

Unchanged: `git -C "$DVW_ROOT" rev-parse --show-superproject-working-tree`.
Non-empty ⇒ superproject mode. The logic stays **generic** — it knows only "my
source has a superproject". No `devMachine` path, repo name, or
`scripts/update-submodules.sh` is hardcoded.

### `cmd_update` flow

`cmd_update` (`lib/commands.sh`) keeps its standalone path verbatim. The
superproject branch delegates to a new `_dvw_update_superproject "$super"`:

1. **Preflight the parent.** Refuse, naming the exact blocker, unless all hold:
   - parent HEAD is on branch `main` (`git -C $super symbolic-ref --short HEAD`);
   - `git -C $super status --porcelain` is empty. This single check also catches
     dirty *submodule contents* (git reports them as ` M devpod/dvw`), so
     in-progress edits in dvw or aicoding can never be clobbered by step 3;
   - after fetching, `origin/main` is a fast-forward from parent HEAD.
2. **Fast-forward the parent.** `git -C $super fetch origin`, then
   `git -C $super merge --ff-only origin/main`. Local unpushed commits on `main`
   need no separate check — `--ff-only` fails there with a clear git error,
   which is surfaced as-is.
3. **Sync submodules to the pins.** `git -C $super submodule update --init --recursive`.
   Deliberately **no `--remote`**: that flag would chase each submodule's own
   `main` and move off the pin, which is the non-goal above.
4. **Re-run the installer.** `bash "$DVW_ROOT/dvw-install.sh"`. `DVW_ROOT` is
   unchanged (same path); its contents are now the pinned commit.
5. **Refresh the behind-cache inline**, exactly as the standalone path does
   today (`DVW_UPDATE_SYNC=1 _dvw_update_do_refresh || true`), so the startup
   nudge and `dvw doctor` don't report a pre-update count for the rest of the
   TTL.
6. **Report.** Parent name/short-sha + subject, and `dvw now at <version>`.

Any failing step aborts with a non-zero exit and a message pointing at the
parent path. Each git invocation goes through the existing `_dvw_run_or_print`,
so `DVW_DRY_RUN=1 dvw update` prints the plan without touching either repo.

### Staleness signal in superproject mode

Today `lib/update-check.sh` measures dvw HEAD against dvw's own `origin/main`,
and `dvw_update_maybe_nudge` prints, for submodule checkouts:

```
⬆ dvw behind main — bump parent submodule pointer (not: dvw update)
```

That CTA becomes wrong once `dvw update` works here. Naively flipping the text
to "run: dvw update" introduces a nag loop: after following the pins, dvw sits
at the parent's pinned commit, which is routinely still behind dvw's own
`origin/main` — so the nudge would fire forever while `dvw update` correctly
reports "already up to date".

Fix: **in superproject mode, measure the parent's staleness instead** — parent
HEAD vs the parent's `origin/main` — and print

```
⬆ <parent-name> behind main — run: dvw update
```

`<parent-name>` is the basename of the superproject working tree (e.g.
`devMachine`). The count goes through the same cache file, TTL, lock, and
fail-open rules as today; only the repo being measured and the message change.
Standalone mode is untouched. This makes the number actionable: it is exactly
what `dvw update` will resolve.

### Error handling

Fail loud on the update path (the user asked for it explicitly), fail open on
the nudge path (advisory, must never break dispatch). Preflight refusals exit 1
and state the blocker plus the parent path, e.g.:

```
✗ devMachine has uncommitted changes — refusing to update
  clean /home/vossi/local_dev/devMachine first (git -C … status)
```

## Testing

New `tests/bats/update-superproject.bats`, using a real git fixture: bare origin
for the parent, bare origin for the submodule, a parent clone with the submodule
added and pinned.

- happy path: parent fast-forwards, submodule HEAD equals the newly pinned SHA,
  installer ran, exit 0;
- refuses when the parent worktree is dirty;
- refuses when the parent has dirty submodule contents;
- refuses when the parent is not on `main`;
- refuses when the parent cannot fast-forward (diverged);
- `DVW_DRY_RUN=1` mutates neither repo.

Plus a nudge test in the update-check suite: superproject mode reports the
*parent's* behind-count and the `run: dvw update` CTA.

Replace the existing `cmd_update: refuses when checkout is a git submodule`
test (`tests/bats/update-refresh.bats`), whose premise this spec inverts.

## Docs to update

- dvw `CLAUDE.md` — the "Updates" section currently says submodule mode is a
  refusal.
- dvw `README.md` — the `dvw update` subcommand row.
- devMachine `CLAUDE.md` — note that `dvw update` now follows the pins, while
  bumping them forward remains `scripts/update-submodules.sh`.
