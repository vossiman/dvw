# dvw update notifier — "behind main → run: dvw update"

**Date:** 2026-06-07
**Status:** design — approved.
**Scope:** dvw, client-side. Add a throttled, fail-open notifier that tells the
user the exact command to run when the dvw checkout is behind `origin/main`.

## Problem

aicoding (in-container) already nudges the user when it's behind, printing the
exact CTA (`⬆ aicoding behind main — run: aicoding-sync`) on the login banner and
a tmux badge. dvw has no equivalent: it ships `dvw update` (manual: `git pull
--ff-only origin main` + re-run installer) and a write-once version marker, but
nothing tells the user *when* to run it. dvw is client-side (Mint/WSL host, never
in a container), so the in-container aicoding notifier deliberately does **not**
track it — its registry is aicoding-only.

## Decisions

**Self-contained module.** A new `lib/update-check.sh` owns the throttle, cache,
and behind-count. No dependency on the deferred client-side aicoding notifier
(spec #1 deferred that; wiring into it would be far larger scope for the same
outcome). The version marker (`lib/version.sh`) stays as-is — write-once at
install, for external readers — and is **not** repurposed for the live check.

**Throttled + background fetch** (mirrors aicoding's notifier shape). Startup
prints the cached result instantly and never blocks; a `git fetch` runs detached
when the cache is stale and updates it for the next run. Fail-open throughout:
offline / timeout / not-a-git-repo → silent, exit 0.

**Surface: startup nudge + doctor.** A one-line nudge near the top of every `dvw`
run when behind, plus a detailed line in `dvw doctor`.

## The module: `lib/update-check.sh`

- **Cache file:** `${DVW_STATE_DIR:-$HOME/.local/state/dvw}/update-check`
  (same dir as the version marker). Stores last-fetch epoch + behind-count.
- **TTL:** `${DVW_UPDATE_TTL:-21600}` (6h), matching aicoding's default knob.
- **`dvw_update_behind_count`** — reader, instant, no network. Echoes the cached
  behind-count, or `0` if the cache is missing/unparsable. Always exit 0.
- **`dvw_update_refresh_if_stale`** — throttled writer. If the cache is older than
  the TTL (or missing): spawn a **detached** `git -C "$DVW_ROOT" fetch -q origin
  main`, then record `behind = git -C "$DVW_ROOT" rev-list --count
  HEAD..origin/main` and the current epoch into the cache. Backgrounded so it never
  blocks the menu. Fail-open: any failure (offline, timeout, `$DVW_ROOT` not a git
  repo, lock contention) leaves the cache untouched and exits 0. A simple
  stamp/lock prevents overlapping fetches.

"Behind" = commits in `origin/main` not reachable from the checkout's `HEAD`
(`HEAD..origin/main`). Correct whether the checkout sits on `main` or a feature
branch. First run after the TTL shows the last cached state, then the background
fetch updates it for the following run.

## Wiring

- **`dvw` `main()`** — after the `--dry-run` argv filter, before subcommand
  dispatch: call `dvw_update_refresh_if_stale` (kicks the throttled background
  fetch), then if `dvw_update_behind_count > 0` print the one-liner:

  ```
  ⬆ dvw behind main — run: dvw update
  ```

  Matches aicoding's format exactly. **Suppressed** when the subcommand is
  `update` (no point nagging mid-update). Silent when up to date or offline.

- **`cmd_doctor()`** — add a check:
  - behind → `ui_status_warn "dvw: N commit(s) behind main — run: \`dvw update\`"`
  - up to date → `ui_status_ok "dvw: up to date with main"`
  - unknown (no cache yet / offline) → `ui_status_ok "dvw: version check pending
    (run again after network)"` (informational, never a doctor failure).

## Out of scope

- Auto-updating (the notice is advisory; `dvw update` stays manual).
- A tmux/status-bar badge (dvw is a CLI, not a long-running pane).
- Client-side aicoding notifier (still deferred, spec #1).
- Changing the version marker's purpose or `cmd_update`.

## Testing (bats)

New `tests/bats/update-check.bats`, isolated `DVW_STATE_DIR` + a local fixture
git remote (no network):

- `dvw_update_behind_count`: reads a cached count; returns `0` when cache
  missing/unparsable; exit 0 always.
- `dvw_update_refresh_if_stale`: stale/missing cache → fetches and records the
  correct behind-count against a fixture remote ahead by N; fresh cache → no
  fetch (assert via a sentinel/marker that the fetch path didn't run).
- Fail-open: `$DVW_ROOT` not a git repo, and an unreachable remote → exit 0, cache
  left intact, no stderr crash.
- `main()` nudge: prints the one-liner only when behind > 0; suppressed for
  `dvw update`; absent when behind == 0.

The existing suite (98 today) stays green; `bash tests/bats/run.sh` runs the
whole thing with no extra env.
