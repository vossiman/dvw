# `dvw update` follows superproject pins — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the dvw checkout is a git submodule of a parent repo, `dvw update` fast-forwards the parent to `origin/main`, checks out every submodule at the commit the parent pins, and re-runs the installer — instead of refusing.

**Architecture:** Two seams. (1) `lib/update-check.sh` learns which repo's staleness matters — the superproject when dvw is pinned, otherwise the dvw checkout — so the behind-count and its CTA become actionable. (2) A new `lib/update-super.sh` holds the superproject update flow; `cmd_update` in `lib/commands.sh` delegates to it where it used to refuse. The logic stays generic: it knows only "my source has a superproject", never `devMachine` by name.

**Tech Stack:** bash 5, git, bats (`./tests/bats/run.sh`).

## Global Constraints

- Never commit, never push, never `git submodule update --remote`. Moving pins forward stays the parent repo's job.
- Detection is generic — no hardcoded `devMachine`, repo URL, or `scripts/update-submodules.sh`.
- Update path fails loud (non-zero + `ui_error` naming the blocker and the parent path). Nudge/doctor path stays fail-open and never blocks dispatch.
- `DVW_DRY_RUN=1` (i.e. `dvw update --dry-run`) must mutate neither repo.
- Spec: `docs/superpowers/specs/2026-07-25-update-follows-superproject-pins-design.md`.
- Run the full suite with `./tests/bats/run.sh` (it exports `DVW_ROOT`). A single file: `DVW_ROOT="$PWD" bats tests/bats/<file>.bats`.
- Work on branch `feat/update-follows-superproject-pins` in the dvw submodule (`devpod/dvw`). `main` is protected — integrate via PR.

---

### Task 1: Staleness targets the superproject

**Files:**
- Modify: `lib/update-check.sh:53-104`
- Modify: `lib/commands.sh:430-447` (the `dvw doctor` advisory line)
- Test: `tests/bats/update-check.bats` (append)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `dvw_superproject_root()` → prints the superproject working-tree path, or nothing. Always exits 0.
  - `dvw_update_target_repo()` → prints the repo path whose staleness is measured: superproject if any, else `$DVW_ROOT`.
  - `dvw_update_target_name()` → prints the display name for that repo: `basename` of the superproject, else `dvw`.
  - `dvw_is_submodule_checkout()` keeps its current name and semantics (true when a superproject exists).

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/update-check.bats`:

```bash
# --- superproject mode -------------------------------------------------------
# When dvw is pinned as a submodule, the staleness that matters is the PARENT's
# (its main is what `dvw update` follows), not dvw's own.

# Build: bare parent remote + parent clone with $REMOTE added as submodule "sub".
# Leaves PARENT set and DVW_ROOT pointing at the submodule checkout.
_make_super() {
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  SUPER_REMOTE="$TMP/super.git"; git init -q --bare -b main "$SUPER_REMOTE"
  PARENT="$TMP/super"; git clone -q "$SUPER_REMOTE" "$PARENT"
  git -C "$PARENT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m super
  git -C "$PARENT" -c user.email=t@t -c user.name=t \
      -c protocol.file.allow=always submodule add -q -b main "$REMOTE" sub
  git -C "$PARENT" -c user.email=t@t -c user.name=t commit -q -m "add sub"
  git -C "$PARENT" push -q origin main
  export DVW_ROOT="$PARENT/sub"
}

# Advance the parent's remote main by N empty commits (throwaway clone).
_advance_super_remote() {
  local n=$1 w2="$TMP/sw2"
  rm -rf "$w2"; git clone -q "$SUPER_REMOTE" "$w2"
  local i; for ((i=0;i<n;i++)); do
    git -C "$w2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "s$i"
  done
  git -C "$w2" push -q origin main
}

@test "superproject_root: empty for a standalone checkout" {
  run dvw_superproject_root
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "superproject_root: the parent working tree for a submodule checkout" {
  _make_super
  run dvw_superproject_root
  [ "$output" = "$PARENT" ]
}

@test "target_repo/name: dvw checkout when standalone" {
  run dvw_update_target_repo
  [ "$output" = "$WORK" ]
  run dvw_update_target_name
  [ "$output" = "dvw" ]
}

@test "target_repo/name: the parent when a submodule checkout" {
  _make_super
  run dvw_update_target_repo
  [ "$output" = "$PARENT" ]
  run dvw_update_target_name
  [ "$output" = "super" ]
}

@test "refresh: counts the PARENT's behind-count in superproject mode" {
  _make_super
  _advance_super_remote 3
  DVW_UPDATE_SYNC=1 dvw_update_refresh_if_stale
  [ "$(dvw_update_behind_count)" = "3" ]
}

@test "refresh: parent stale but dvw pin current still reports behind" {
  # The exact loop the old CTA caused: dvw's own main may be ahead of the pin
  # forever. What we report is the parent's, which `dvw update` can resolve.
  _make_super
  _advance_remote 5          # dvw's own main moves; the pin does not
  _advance_super_remote 1
  DVW_UPDATE_SYNC=1 dvw_update_refresh_if_stale
  [ "$(dvw_update_behind_count)" = "1" ]
}

@test "nudge: superproject mode names the parent and says run: dvw update" {
  _make_super
  _write_cache "$(date +%s)" 2
  run dvw_update_maybe_nudge status
  [[ "$output" == *"super behind main"* ]]
  [[ "$output" == *"run: dvw update"* ]]
  [[ "$output" != *"bump parent"* ]]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: the seven new tests FAIL (`dvw_superproject_root: command not found`; the nudge test fails on the old `bump parent submodule pointer` text).

- [ ] **Step 3: Implement in `lib/update-check.sh`**

Replace the block from `_dvw_update_do_refresh` (line 53) to end of file with:

```bash
_dvw_update_do_refresh() {
  local cache behind now tmp repo
  cache=$(dvw_update_cache_path)
  repo=$(dvw_update_target_repo)
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  git -C "$repo" fetch -q --no-write-fetch-head origin main 2>/dev/null || return 0
  behind=$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null)
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  now=$(date +%s)
  tmp="${cache}.tmp.$$"
  printf '%s\n%s\n' "$now" "$behind" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
  return 0
}

# Refresh the cache iff stale. Fail-open and non-blocking: the fetch runs
# detached in the background (the foreground returns immediately and prints the
# CURRENT cached state). Set DVW_UPDATE_SYNC=1 to run it inline (tests).
dvw_update_refresh_if_stale() {
  _dvw_update_cache_stale || return 0
  git -C "$(dvw_update_target_repo)" rev-parse --git-dir >/dev/null 2>&1 || return 0
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

# Echo the working tree of the superproject that pins $DVW_ROOT as a submodule
# (e.g. devMachine), or nothing when this is a standalone checkout. Always 0.
dvw_superproject_root() {
  git -C "${DVW_ROOT:?}" rev-parse --show-superproject-working-tree 2>/dev/null || true
}

# True when $DVW_ROOT is a git submodule of another working tree.
dvw_is_submodule_checkout() {
  [[ -n "$(dvw_superproject_root)" ]]
}

# Which repo's staleness is worth reporting? Under a superproject it is the
# PARENT's: dvw sits at whatever commit the parent pins, so dvw's own main is
# routinely ahead of it and would nag forever. The parent's distance from its
# main is exactly what `dvw update` resolves.
dvw_update_target_repo() {
  local super; super=$(dvw_superproject_root)
  printf '%s' "${super:-${DVW_ROOT:?}}"
}

# Display name for that repo: the superproject's directory name, else "dvw".
dvw_update_target_name() {
  local super; super=$(dvw_superproject_root)
  if [[ -n "$super" ]]; then printf '%s' "$(basename "$super")"; else printf 'dvw'; fi
}

# Print the one-line startup nudge if behind. $1 = the subcommand being
# dispatched; the nudge is suppressed for `update` (no point nagging mid-update)
# and silent when up to date (0) or unknown (empty). Reads cached state only.
dvw_update_maybe_nudge() {
  [ "${1:-}" = "update" ] && return 0
  local behind; behind=$(dvw_update_behind_count)
  case "$behind" in ''|0) return 0 ;; esac
  printf '⬆ %s behind main — run: dvw update\n' "$(dvw_update_target_name)"
}
```

Also update the file's header comment (lines 1-3) — it says "is the dvw checkout behind origin/main?". Replace with:

```bash
# dvw update notifier — is the tracked repo behind origin/main? That is the dvw
# checkout when standalone, and the SUPERPROJECT that pins it when dvw is a
# submodule (see dvw_update_target_repo). Throttled, fail-open, never blocks.
# The startup nudge (in `dvw`) and `dvw doctor` read the cached result; a
# detached `git fetch` refreshes it past the TTL.
```

- [ ] **Step 4: Run the update-check suite to verify it passes**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-check.bats`
Expected: PASS, all tests (pre-existing standalone ones included — they must be unaffected).

- [ ] **Step 5: Update the `dvw doctor` advisory line**

In `lib/commands.sh`, replace lines 438-443 (the `elif`/`if dvw_is_submodule_checkout` branch) with a single message:

```bash
    elif [[ "$_dvw_behind" -gt 0 ]]; then
      local _dvw_name=dvw
      command -v dvw_update_target_name >/dev/null 2>&1 && _dvw_name=$(dvw_update_target_name)
      ui_status_warn "$_dvw_name: $_dvw_behind commit(s) behind main — run: \`dvw update\`"
```

Leave the surrounding `if command -v dvw_update_behind_count` guard and the `ui_status_ok` branches untouched.

- [ ] **Step 6: Run the full suite**

Run: `./tests/bats/run.sh`
Expected: all files pass except `tests/bats/update-refresh.bats`'s `refuses when checkout is a git submodule`, which Task 2 replaces. If any *other* test fails, fix it before committing.

- [ ] **Step 7: Commit**

```bash
git add lib/update-check.sh lib/commands.sh tests/bats/update-check.bats
git commit -m "feat: measure staleness against the superproject when dvw is pinned"
```

---

### Task 2: `dvw update` follows the pins

**Files:**
- Create: `lib/update-super.sh`
- Modify: `lib/commands.sh:72-98` (`cmd_update`)
- Modify: `dvw:29-30` (source the new lib)
- Create: `tests/bats/update-superproject.bats`
- Modify: `tests/bats/update-refresh.bats:66-80` (replace the refusal test)

**Interfaces:**
- Consumes: `dvw_installed_version` (`lib/version.sh`), `_dvw_update_do_refresh` (`lib/update-check.sh`, Task 1), `ui_error` / `ui_info` (`lib/ui.sh`).
- Produces: `_dvw_update_superproject <super-path>` → 0 on success, 1 with a `ui_error` on any refusal or failure. `_dvw_super_preflight <super-path>` → 0 when the parent is on `main` and clean, else 1 with the blocker named.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/update-superproject.bats`:

```bash
#!/usr/bin/env bats
#
# `dvw update` in superproject mode (spec 2026-07-25): when the dvw checkout is
# a submodule, the newest *released* tooling is what the parent's main pins.
# Update therefore follows the pins — ff the parent, check submodules out at the
# pinned commits, re-run the installer. It never commits and never pushes.
#
# Fixture: bare submodule remote + bare parent remote + a parent clone acting as
# the superproject. Installer is stubbed (the real one runs apt/sudo/network).

setup() {
  : "${DVW_ROOT:?}"
  REAL_ROOT="$DVW_ROOT"                       # capture before repointing
  TMP=$(mktemp -d); export HOME="$TMP"
  export DVW_STATE_DIR="$TMP/state"
  export DVW_UPDATE_TTL=21600
  unset DVW_UPDATE_SYNC DVW_DRY_RUN
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  # Submodule "dvw" remote, with one commit on main.
  SUB_REMOTE="$TMP/sub.git"; git init -q --bare -b main "$SUB_REMOTE"
  local seed="$TMP/seed"; git clone -q "$SUB_REMOTE" "$seed"
  mkdir -p "$seed/lib"
  # cmd_update sources these two from $DVW_ROOT, which here is the submodule.
  cp "$REAL_ROOT/lib/version.sh" "$seed/lib/version.sh"
  cp "$REAL_ROOT/lib/update-super.sh" "$seed/lib/update-super.sh"
  printf '#!/usr/bin/env bash\necho ran-installer >> "$INSTALL_LOG"\n' > "$seed/dvw-install.sh"
  chmod +x "$seed/dvw-install.sh"
  git -C "$seed" add -A; git -C "$seed" commit -q -m sub-base
  git -C "$seed" push -q origin main

  # Parent remote + clone, pinning the submodule at that commit.
  SUPER_REMOTE="$TMP/super.git"; git init -q --bare -b main "$SUPER_REMOTE"
  PARENT="$TMP/super"; git clone -q "$SUPER_REMOTE" "$PARENT"
  git -C "$PARENT" commit -q --allow-empty -m super-base
  git -C "$PARENT" -c protocol.file.allow=always submodule add -q -b main "$SUB_REMOTE" sub
  git -C "$PARENT" commit -q -m "add sub"
  git -C "$PARENT" push -q origin main
  git -C "$PARENT" config protocol.file.allow always

  export INSTALL_LOG="$TMP/install.log"; : > "$INSTALL_LOG"
  source "$REAL_ROOT/lib/connect.sh"          # _dvw_run_or_print (dry-run)
  source "$REAL_ROOT/lib/update-check.sh"
  source "$REAL_ROOT/lib/commands.sh"
  ui_info()  { printf 'INFO: %s\n' "$*"; }
  ui_error() { printf 'ERROR: %s\n' "$*" >&2; }
  ui_action() { :; }

  export DVW_ROOT="$PARENT/sub"
}
teardown() { rm -rf "$TMP"; }

# Push a new submodule commit AND a parent commit that pins it. Echoes the
# newly pinned submodule SHA.
_advance_pin() {
  local w="$TMP/adv"; rm -rf "$w"
  git clone -q "$SUB_REMOTE" "$w"
  git -C "$w" commit -q --allow-empty -m sub-next
  git -C "$w" push -q origin main
  local sha; sha=$(git -C "$w" rev-parse HEAD)

  local p="$TMP/advp"; rm -rf "$p"
  git clone -q --recurse-submodules -c protocol.file.allow=always "$SUPER_REMOTE" "$p"
  git -C "$p" -c protocol.file.allow=always submodule update --init -q
  git -C "$p/sub" fetch -q origin main
  git -C "$p/sub" checkout -q "$sha"
  git -C "$p" add sub
  git -C "$p" commit -q -m "bump sub"
  git -C "$p" push -q origin main
  printf '%s' "$sha"
}

@test "cmd_update: follows the parent's pins" {
  local sha; sha=$(_advance_pin)
  run cmd_update
  [ "$status" -eq 0 ]
  # Parent fast-forwarded, submodule checked out at the newly pinned commit.
  [ "$(git -C "$PARENT" rev-parse HEAD)" = "$(git -C "$PARENT" rev-parse origin/main)" ]
  [ "$(git -C "$PARENT/sub" rev-parse HEAD)" = "$sha" ]
  # Installer ran; nothing was committed on top of the ff.
  [ -s "$INSTALL_LOG" ]
  [ -z "$(git -C "$PARENT" status --porcelain)" ]
}

@test "cmd_update: does not chase the submodule's own main past the pin" {
  # Submodule main moves; the parent does NOT bump. Following pins must leave
  # the submodule where the parent pinned it.
  local before; before=$(git -C "$PARENT/sub" rev-parse HEAD)
  local w="$TMP/solo"; git clone -q "$SUB_REMOTE" "$w"
  git -C "$w" commit -q --allow-empty -m unpinned
  git -C "$w" push -q origin main
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(git -C "$PARENT/sub" rev-parse HEAD)" = "$before" ]
}

@test "cmd_update: refuses when the parent worktree is dirty" {
  echo dirt > "$PARENT/dirt.txt"
  git -C "$PARENT" add dirt.txt
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [[ "$output" == *"$PARENT"* ]]
}

@test "cmd_update: refuses when submodule contents are dirty" {
  echo scratch > "$PARENT/sub/WIP.txt"
  git -C "$PARENT/sub" add WIP.txt
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
  # The in-progress file survives.
  [ -f "$PARENT/sub/WIP.txt" ]
}

@test "cmd_update: refuses when the parent is not on main" {
  git -C "$PARENT" checkout -q -b feat/x
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on main"* ]]
  [[ "$output" == *"feat/x"* ]]
}

@test "cmd_update: refuses when the parent cannot fast-forward" {
  _advance_pin >/dev/null
  git -C "$PARENT" commit -q --allow-empty -m local-divergence
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"fast-forward"* ]]
}

@test "cmd_update: dry-run mutates neither repo" {
  _advance_pin >/dev/null
  local psha ssha
  psha=$(git -C "$PARENT" rev-parse HEAD); ssha=$(git -C "$PARENT/sub" rev-parse HEAD)
  DVW_DRY_RUN=1 run cmd_update
  [ "$status" -eq 0 ]
  [ "$(git -C "$PARENT" rev-parse HEAD)" = "$psha" ]
  [ "$(git -C "$PARENT/sub" rev-parse HEAD)" = "$ssha" ]
  [ ! -s "$INSTALL_LOG" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-superproject.bats`
Expected: all FAIL — `cmd_update` still refuses, so `status` is 1 and output contains "refusing `dvw update`".

- [ ] **Step 3: Create `lib/update-super.sh`**

```bash
# Superproject-aware update (spec 2026-07-25).
#
# When the dvw checkout is a git submodule of a parent repo (devMachine pins
# devpod/dvw), the newest *released* tooling is what the parent's main pins —
# not dvw's own main. `dvw update` therefore FOLLOWS the pins: fast-forward the
# parent, check every submodule out at the pinned commit, re-run the installer.
#
# It never commits and never pushes. Moving the pins forward (submodule update
# --remote + a pointer-bump commit) stays the parent repo's job.
#
# Nothing here knows the parent by name — only "my source has a superproject".

# Run a command, or print it under --dry-run. Mirrors _dvw_run_or_print from
# lib/connect.sh, which isn't guaranteed to be sourced when this lib is.
_dvw_super_run() {
  if command -v _dvw_run_or_print >/dev/null 2>&1; then
    _dvw_run_or_print "$@"
  else
    "$@"
  fi
}

# Refuse unless the parent is on main with a clean worktree. `status --porcelain`
# also reports dirty SUBMODULE contents (as " M sub"), so in-progress edits in
# dvw or aicoding can never be clobbered by the submodule checkout below.
_dvw_super_preflight() {
  local super="$1" name branch
  name=$(basename "$super")
  branch=$(git -C "$super" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [[ "$branch" != "main" ]]; then
    ui_error "$name is not on main (HEAD: ${branch:-detached}) — refusing to update"
    ui_info "switch $super to main first"
    return 1
  fi
  if [[ -n "$(git -C "$super" status --porcelain 2>/dev/null)" ]]; then
    ui_error "$name has uncommitted changes — refusing to update"
    ui_info "commit or stash first: git -C $super status"
    return 1
  fi
  return 0
}

# $1 = superproject working tree. 0 on success; 1 with a ui_error otherwise.
_dvw_update_superproject() {
  local super="$1" name
  name=$(basename "$super")
  ui_info "updating $name in $super (following pinned submodules)"
  _dvw_super_preflight "$super" || return 1

  _dvw_super_run git -C "$super" fetch -q origin main || {
    ui_error "git fetch failed in $super"; return 1; }
  # --ff-only also covers local unpushed commits on main: it fails there rather
  # than merging, and git's own message says why.
  _dvw_super_run git -C "$super" merge --ff-only origin/main || {
    ui_error "$name cannot fast-forward to origin/main — resolve manually in $super"
    return 1; }
  # No --remote, deliberately: that chases each submodule's own main and moves
  # off the pin, which is the parent repo's call to make, not ours.
  _dvw_super_run git -C "$super" submodule update --init --recursive || {
    ui_error "submodule update failed in $super"; return 1; }

  _dvw_super_run bash "$DVW_ROOT/dvw-install.sh" || {
    ui_error "dvw-install.sh failed"; return 1; }

  # Same rationale as the standalone path: the cached behind-count predates the
  # update and would survive the TTL, so refresh it inline. Fail-open.
  if command -v _dvw_update_do_refresh >/dev/null 2>&1; then
    DVW_UPDATE_SYNC=1 _dvw_update_do_refresh || true
  fi

  ui_info "$name now at $(git -C "$super" log -1 --format='%h %s' 2>/dev/null)"
  ui_info "dvw now at $(dvw_installed_version)"
}
```

- [ ] **Step 4: Wire it into `cmd_update`**

In `lib/commands.sh`, replace the comment block and refusal (lines 72-84) with:

```bash
# dvw update — manual, user-invoked in-place update. NEVER called automatically.
# Standalone checkout: pull latest main, re-run the installer, refresh the
# version marker. Submodule checkout (e.g. devMachine pins devpod/dvw): follow
# the parent's pins instead — see lib/update-super.sh.
cmd_update() {
  . "$DVW_ROOT/lib/version.sh"
  local super
  super=$(git -C "$DVW_ROOT" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  if [[ -n "$super" ]]; then
    . "$DVW_ROOT/lib/update-super.sh"
    _dvw_update_superproject "$super"
    return $?
  fi
```

The rest of `cmd_update` (the standalone `git pull` onward) is unchanged.

(Step 1's fixture already copies `lib/update-super.sh` into the seeded submodule, because `cmd_update` sources it from `$DVW_ROOT`. Until Step 3 exists, that `cp` fails — which is why Step 2's tests fail rather than error out at setup once the file lands.)

- [ ] **Step 5: Source the new lib from the dispatcher**

In `dvw`, after the `lib/update-check.sh` source line (line 30), add:

```bash
# shellcheck source=lib/update-super.sh
. "$DVW_ROOT/lib/update-super.sh"
```

(`cmd_update` also sources it directly, so it works when `commands.sh` is loaded in isolation; sourcing here keeps `dvw --help`/shellcheck consistent with the other libs.)

- [ ] **Step 6: Run the new suite to verify it passes**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-superproject.bats`
Expected: PASS, 7 tests.

- [ ] **Step 7: Replace the stale refusal test**

In `tests/bats/update-refresh.bats`, delete the whole `@test "cmd_update: refuses when checkout is a git submodule"` block (lines 66-80) — this spec inverts its premise, and `update-superproject.bats` now covers that mode.

- [ ] **Step 8: Run the full suite**

Run: `./tests/bats/run.sh`
Expected: everything passes.

- [ ] **Step 9: Commit**

```bash
git add lib/update-super.sh lib/commands.sh dvw tests/bats/update-superproject.bats tests/bats/update-refresh.bats
git commit -m "feat: dvw update follows superproject pins instead of refusing"
```

---

### Task 3: Docs

**Files:**
- Modify: `CLAUDE.md` (the "Updates" section)
- Modify: `README.md:37` (the `dvw update` row) and `README.md:146-167` ("Updating dvw")
- Modify: `../../CLAUDE.md` — devMachine's, at the repo root above the submodule

**Interfaces:**
- Consumes: behaviour from Tasks 1-2. Produces: nothing code-facing.

- [ ] **Step 1: Update dvw `CLAUDE.md`**

Replace the "Updates" section with:

```markdown
## Updates

- Standalone checkout: `dvw update` (pull main + reinstall).
- Submodule under a parent (e.g. `devMachine`): `dvw update` **follows the
  parent's pins** — ff the parent to its `origin/main`, check submodules out at
  the pinned commits, reinstall. It never commits or pushes; moving the pins
  forward is the parent's job (`scripts/update-submodules.sh` in devMachine).
  It refuses when the parent is off `main`, dirty (including dirty submodule
  contents), or can't fast-forward. See `lib/update-super.sh`.
- The "behind main" nudge measures the **parent** in submodule mode, so the
  count is exactly what `dvw update` resolves (`lib/update-check.sh`).
```

- [ ] **Step 2: Update dvw `README.md`**

Replace the `dvw update` table row (line 37) with:

```markdown
| `dvw update` | Update to the latest released tooling and refresh the version marker. Standalone checkout: pull `main` + reinstall. Submodule checkout: follow the parent's pins (ff the parent, check out pinned submodules, reinstall) — never commits or pushes. Startup/`dvw doctor` nudge when behind `origin/main`. |
```

Replace the "Submodule consumer" subsection under "Updating dvw" (lines 156-166) with:

```markdown
### Submodule consumer

    dvw update

Follows the parent's pins: fast-forwards the parent repo to its `origin/main`,
checks every submodule out at the commit the parent pins, and re-runs
`dvw-install.sh`. Creates no commits — nothing to push. Refuses (naming the
blocker) if the parent is off `main`, has uncommitted changes, or can't
fast-forward.

To move the pin *forward* instead — a maintainer action that commits — bump it
in the parent:

    git submodule update --remote devpod/dvw
    git add devpod/dvw
    git commit -m "devpod/dvw: bump to <sha>"
```

- [ ] **Step 3: Update devMachine's `CLAUDE.md`**

In `/workspaces/devmachine/CLAUDE.md`, append to the "END of session: bump submodule pointers to latest `main`" section's Rules list:

```markdown
- Bumping pointers (this section) is the *maintainer* direction. The consumer
  direction is `dvw update`, which follows the pins: it fast-forwards this repo
  to `origin/main` and checks the submodules out at their pinned commits. It
  never commits or pushes, and refuses when this repo is off `main`, dirty, or
  can't fast-forward.
```

- [ ] **Step 4: Verify the docs match reality**

Run: `DVW_ROOT="$PWD" bats tests/bats/update-superproject.bats && grep -n "follows the parent" CLAUDE.md README.md`
Expected: tests PASS and both files show the new wording.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: dvw update follows superproject pins"
```

devMachine's `CLAUDE.md` lives in the parent repo — commit it there separately:

```bash
git -C ../.. add CLAUDE.md
git -C ../.. commit -m "docs: note dvw update follows the pins"
```

---

## Wrap-up

- [ ] Run `./tests/bats/run.sh` one final time — all green.
- [ ] Manually sanity-check the refusal text: `DVW_ROOT=/path/to/devMachine/devpod/dvw dvw update --dry-run` from a dirty devMachine prints the blocker and changes nothing.
- [ ] Push the branch and open a PR against dvw `main` (protected — do not push to `main`). Ask before merging.
- [ ] After merge: bump devMachine's `devpod/dvw` pointer (`bash scripts/update-submodules.sh && git push`) and delete the merged branch.
