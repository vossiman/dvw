# dvw update notifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the dvw checkout is behind `origin/main`, tell the user the exact command to run (`dvw update`) — as a throttled, fail-open startup nudge and a `dvw doctor` line.

**Architecture:** A self-contained `lib/update-check.sh` owns a TTL-throttled cache and a detached background `git fetch`. Pure readers (`dvw_update_behind_count`, `dvw_update_maybe_nudge`) never touch the network; `dvw_update_refresh_if_stale` kicks the fetch only past the TTL. `dvw` `main()` and `cmd_doctor()` call these. No dependency on aicoding.

**Tech Stack:** Bash (sourced library, `set -euo pipefail`), git, bats.

Spec: `docs/superpowers/specs/2026-06-07-update-notifier-design.md`

**Conventions for every task below:**
- Run the focused test file with: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
- Run the whole suite with: `bash tests/bats/run.sh` (must stay green; 98 today).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Work on branch `feat/update-notifier` (already created).

---

## Task 1: Cache path + behind-count reader

**Files:**
- Create: `lib/update-check.sh`
- Test: `tests/bats/update-check.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/update-check.bats`:

```bash
#!/usr/bin/env bats
#
# dvw update notifier (spec 2026-06-07): is the checkout behind origin/main?
# Throttled, fail-open, never blocks. Tests use a local fixture remote (no net).

setup() {
  : "${DVW_ROOT:?}"
  LIB="$DVW_ROOT/lib/update-check.sh"        # capture before we repoint DVW_ROOT
  TMP=$(mktemp -d); export HOME="$TMP"
  export DVW_STATE_DIR="$TMP/state"
  export DVW_UPDATE_TTL=21600
  unset DVW_UPDATE_SYNC

  # Fixture: a bare "remote" + a working clone that acts as the dvw checkout.
  REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
  WORK="$TMP/work"; git clone -q "$REMOTE" "$WORK"
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WORK" push -q origin HEAD:main
  git -C "$WORK" branch -q -M main
  git -C "$WORK" branch -q --set-upstream-to=origin/main main

  source "$LIB"
  export DVW_ROOT="$WORK"                     # functions operate on the fixture
}
teardown() { rm -rf "$TMP"; }

# Advance the remote main by N empty commits (via a throwaway second clone).
_advance_remote() {
  local n=$1 w2="$TMP/w2"
  rm -rf "$w2"; git clone -q "$REMOTE" "$w2"
  git -C "$w2" -c user.email=t@t -c user.name=t checkout -q main
  local i; for ((i=0;i<n;i++)); do
    git -C "$w2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "c$i"
  done
  git -C "$w2" push -q origin main
}

_write_cache() { mkdir -p "$DVW_STATE_DIR"; printf '%s\n%s\n' "$1" "$2" > "$DVW_STATE_DIR/update-check"; }

@test "behind_count: empty (unknown) when no cache" {
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "behind_count: echoes the cached count" {
  _write_cache 123 3
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "behind_count: empty when count is unparsable" {
  _write_cache 123 xyz
  run dvw_update_behind_count
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: FAIL — `dvw_update_behind_count: command not found` (lib doesn't exist).

- [ ] **Step 3: Create `lib/update-check.sh` with the reader**

```bash
# dvw update notifier — is the dvw checkout behind origin/main? Throttled,
# fail-open, never blocks. The startup nudge (in `dvw`) and `dvw doctor` read
# the cached result; a detached `git fetch` refreshes it past the TTL.
#
# Cache file: two lines — <last-fetch-epoch>\n<behind-count>\n — in the same
# state dir as the version marker. dvw owns it; nothing else writes here.

# Throttle window (seconds). Matches aicoding's AICODING_UPDATE_TTL default.
DVW_UPDATE_TTL="${DVW_UPDATE_TTL:-21600}"   # 6h

dvw_update_cache_path() {
  printf '%s/update-check' "${DVW_STATE_DIR:-$HOME/.local/state/dvw}"
}

# Echo the cached behind-count. Empty = unknown (no/garbled cache). No network.
# Callers treat empty as "not checked yet" and 0 as "up to date". Always exit 0.
dvw_update_behind_count() {
  local cache count
  cache=$(dvw_update_cache_path)
  [ -f "$cache" ] || return 0
  count=$(sed -n '2p' "$cache" 2>/dev/null)
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "$count" ;;
  esac
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/update-check.sh tests/bats/update-check.bats
git commit -m "feat(update-check): cache path + behind-count reader"
```

---

## Task 2: Staleness predicate

**Files:**
- Modify: `lib/update-check.sh`
- Test: `tests/bats/update-check.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/update-check.bats`:

```bash
@test "cache_stale: true (status 0) when cache missing" {
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}

@test "cache_stale: false (status 1) when cache is fresh" {
  _write_cache "$(date +%s)" 0
  run _dvw_update_cache_stale
  [ "$status" -ne 0 ]
}

@test "cache_stale: true (status 0) when cache older than TTL" {
  _write_cache 1 0           # epoch 1 = 1970, far older than any TTL
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}

@test "cache_stale: true when epoch is unparsable" {
  _write_cache nope 0
  run _dvw_update_cache_stale
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: FAIL — `_dvw_update_cache_stale: command not found`.

- [ ] **Step 3: Add the predicate to `lib/update-check.sh`**

Append after `dvw_update_behind_count`:

```bash
# Return 0 (stale → should refresh) if the cache is missing, unparsable, or
# older than DVW_UPDATE_TTL. Return 1 (fresh) otherwise.
_dvw_update_cache_stale() {
  local cache epoch now
  cache=$(dvw_update_cache_path)
  [ -f "$cache" ] || return 0
  epoch=$(sed -n '1p' "$cache" 2>/dev/null)
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $(( now - epoch )) -ge "$DVW_UPDATE_TTL" ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/update-check.sh tests/bats/update-check.bats
git commit -m "feat(update-check): TTL staleness predicate"
```

---

## Task 3: Synchronous refresh core (fetch + record)

**Files:**
- Modify: `lib/update-check.sh`
- Test: `tests/bats/update-check.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/update-check.bats`:

```bash
@test "do_refresh: records the correct behind-count against the remote" {
  _advance_remote 2
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "2" ]
}

@test "do_refresh: records 0 when up to date" {
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "0" ]
}

@test "do_refresh: fail-open (exit 0, no cache) when remote is unreachable" {
  git -C "$DVW_ROOT" remote set-url origin "$TMP/does-not-exist.git"
  run _dvw_update_do_refresh
  [ "$status" -eq 0 ]
  [ ! -f "$DVW_STATE_DIR/update-check" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: FAIL — `_dvw_update_do_refresh: command not found`.

- [ ] **Step 3: Add the refresh core to `lib/update-check.sh`**

Append after `_dvw_update_cache_stale`:

```bash
# Synchronous refresh: fetch origin/main, record <epoch>\n<behind>. Fail-open —
# any failure (offline, bad remote) returns 0 and leaves the cache untouched, so
# the next run simply retries. Writes atomically via a temp file + mv.
_dvw_update_do_refresh() {
  local cache behind now tmp
  cache=$(dvw_update_cache_path)
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  git -C "$DVW_ROOT" fetch -q origin main 2>/dev/null || return 0
  behind=$(git -C "$DVW_ROOT" rev-list --count HEAD..origin/main 2>/dev/null)
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  now=$(date +%s)
  tmp="${cache}.tmp.$$"
  printf '%s\n%s\n' "$now" "$behind" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/update-check.sh tests/bats/update-check.bats
git commit -m "feat(update-check): synchronous fetch+record refresh core"
```

---

## Task 4: Throttled refresh dispatcher (background + sync knob)

**Files:**
- Modify: `lib/update-check.sh`
- Test: `tests/bats/update-check.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/update-check.bats`. (`DVW_UPDATE_SYNC=1` forces the
foreground path so the test is deterministic — no async.)

```bash
@test "refresh_if_stale: stale cache refreshes (sync mode) and records count" {
  export DVW_UPDATE_SYNC=1
  _advance_remote 3
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "3" ]
}

@test "refresh_if_stale: fresh cache does NOT refresh (count stays put)" {
  export DVW_UPDATE_SYNC=1
  _write_cache "$(date +%s)" 0     # fresh, says up-to-date
  _advance_remote 5                # remote moves ahead, but cache is fresh
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
  [ "$(dvw_update_behind_count)" = "0" ]   # unchanged — no fetch happened
}

@test "refresh_if_stale: fail-open (exit 0) when DVW_ROOT is not a git repo" {
  export DVW_ROOT="$TMP/notgit"; mkdir -p "$DVW_ROOT"
  run dvw_update_refresh_if_stale
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: FAIL — `dvw_update_refresh_if_stale: command not found`.

- [ ] **Step 3: Add the dispatcher to `lib/update-check.sh`**

Append after `_dvw_update_do_refresh`:

```bash
# Refresh the cache iff stale. Fail-open and non-blocking: the fetch runs
# detached in the background (the foreground returns immediately and prints the
# CURRENT cached state). Set DVW_UPDATE_SYNC=1 to run it inline (tests).
dvw_update_refresh_if_stale() {
  _dvw_update_cache_stale || return 0
  git -C "$DVW_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if [ -n "${DVW_UPDATE_SYNC:-}" ]; then
    _dvw_update_do_refresh
    return 0
  fi
  local lock; lock="$(dvw_update_cache_path).lock"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 0
  mkdir "$lock" 2>/dev/null || return 0     # another refresh already in flight
  ( _dvw_update_do_refresh; rmdir "$lock" 2>/dev/null || true ) >/dev/null 2>&1 &
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/update-check.sh tests/bats/update-check.bats
git commit -m "feat(update-check): throttled background refresh dispatcher"
```

---

## Task 5: Nudge printer (with `update`-subcommand suppression)

**Files:**
- Modify: `lib/update-check.sh`
- Test: `tests/bats/update-check.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/update-check.bats`:

```bash
@test "maybe_nudge: prints the CTA line when behind and subcommand != update" {
  _write_cache 123 2
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind main — run: dvw update"* ]]
}

@test "maybe_nudge: silent for the update subcommand even when behind" {
  _write_cache 123 2
  run dvw_update_maybe_nudge update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "maybe_nudge: silent when up to date (count 0)" {
  _write_cache 123 0
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "maybe_nudge: silent when unknown (no cache)" {
  run dvw_update_maybe_nudge connect
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: FAIL — `dvw_update_maybe_nudge: command not found`.

- [ ] **Step 3: Add the nudge printer to `lib/update-check.sh`**

Append after `dvw_update_refresh_if_stale`:

```bash
# Print the one-line startup nudge if behind. $1 = the subcommand being
# dispatched; the nudge is suppressed for `update` (no point nagging mid-update)
# and silent when up to date (0) or unknown (empty). Reads cached state only.
dvw_update_maybe_nudge() {
  [ "${1:-}" = "update" ] && return 0
  local behind; behind=$(dvw_update_behind_count)
  case "$behind" in ''|0) return 0 ;; esac
  printf '⬆ dvw behind main — run: dvw update\n'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/update-check.sh tests/bats/update-check.bats
git commit -m "feat(update-check): startup nudge printer"
```

---

## Task 6: Wire into `dvw` main() and `cmd_doctor()`

**Files:**
- Modify: `dvw` (sourcing block ~line 4-19; `main()` after the `--dry-run` filter ~line 37)
- Modify: `lib/commands.sh` (`cmd_doctor`, after the `jq` check)

No new unit tests here (the functions are covered in Tasks 1-5; this is thin glue
that would otherwise require stubbing devpod/catalog). Verification is the full
suite staying green plus a manual smoke.

- [ ] **Step 1: Source the lib in `dvw`**

In `dvw`, add to the sourcing block (after the `lib/ui.sh` line, ~line 19):

```bash
# shellcheck source=lib/update-check.sh
. "$DVW_ROOT/lib/update-check.sh"
```

- [ ] **Step 2: Call the notifier in `main()`**

In `dvw`, find the end of the `--dry-run` handling block — the lines:

```bash
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] no commands will be executed; would-be invocations are printed"
  fi
```

Immediately AFTER that `fi`, insert:

```bash

  # Update notifier: kick a throttled background fetch, then print the cached
  # "behind main" nudge (suppressed for `dvw update` itself). Fail-open.
  dvw_update_refresh_if_stale
  dvw_update_maybe_nudge "${1:-}"
```

- [ ] **Step 3: Add the doctor check in `lib/commands.sh`**

In `cmd_doctor`, find the `jq` check:

```bash
  # jq
  if command -v jq >/dev/null; then
    ui_status_ok "jq: $(jq --version)"
  else
    ui_status_fail "jq: not on PATH"
    fail=$((fail+1))
  fi
```

Immediately AFTER that block, insert:

```bash

  # dvw version vs origin/main (advisory; never a doctor failure). Guarded so
  # the check is a no-op if update-check.sh wasn't sourced (e.g. a test that
  # sources commands.sh in isolation).
  if command -v dvw_update_behind_count >/dev/null 2>&1; then
    dvw_update_refresh_if_stale
    local _dvw_behind; _dvw_behind=$(dvw_update_behind_count)
    if [[ -z "$_dvw_behind" ]]; then
      ui_status_ok "dvw: version check pending (run again after network)"
    elif [[ "$_dvw_behind" -gt 0 ]]; then
      ui_status_warn "dvw: $_dvw_behind commit(s) behind main — run: \`dvw update\`"
    else
      ui_status_ok "dvw: up to date with main"
    fi
  fi
```

- [ ] **Step 4: Verify the whole suite stays green**

Run: `bash tests/bats/run.sh`
Expected: all green (98 existing + 17 new = 115; 0 failures).

- [ ] **Step 5: Manual smoke (behind path)**

Run, from the dvw checkout:

```bash
DVW_STATE_DIR=$(mktemp -d) bash -c '
  . ./lib/update-check.sh
  printf "%s\n%s\n" 123 2 > "$DVW_STATE_DIR/update-check"
  DVW_ROOT="$PWD" dvw_update_maybe_nudge connect
'
```

Expected output: `⬆ dvw behind main — run: dvw update`

- [ ] **Step 6: Commit**

```bash
git add dvw lib/commands.sh
git commit -m "feat(dvw): wire update notifier into startup + doctor"
```

---

## Task 7: README — document the notifier

**Files:**
- Modify: `README.md` (the `dvw update` subcommand row / a short note)

- [ ] **Step 1: Update the `dvw update` row**

In `README.md`, find the subcommands table row:

```
| `dvw update` | Update dvw in place to latest main and refresh the version marker. |
```

Replace with:

```
| `dvw update` | Update dvw in place to latest main and refresh the version marker. dvw nudges you to run this (and `dvw doctor` reports it) when the checkout falls behind `origin/main`. |
```

- [ ] **Step 2: Verify suite still green (docs-only, sanity)**

Run: `bash tests/bats/run.sh`
Expected: all green, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: note the dvw update notifier in the subcommands table"
```

---

## Done

Push the branch and open a PR against `main` (protected — do not merge without approval):

```bash
git push -u origin feat/update-notifier
set -a; . ~/.aicodingsetup/.secrets.env; set +a
gh pr create --base main --head feat/update-notifier \
  --title "dvw update notifier (behind main → run: dvw update)" \
  --body "Throttled, fail-open client-side notifier: a startup nudge and a \`dvw doctor\` line tell the user to run \`dvw update\` when the checkout is behind \`origin/main\`. Self-contained \`lib/update-check.sh\` (background \`git fetch\` + TTL cache); mirrors aicoding's notifier shape, no dependency on it. New \`tests/bats/update-check.bats\` (17 tests); suite green. Spec: \`docs/superpowers/specs/2026-06-07-update-notifier-design.md\`."
```
