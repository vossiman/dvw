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
  git clone -q "$SUPER_REMOTE" "$p"
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

@test "cmd_update: drifted-but-clean submodule HEAD gets a submodule-update hint, not 'uncommitted changes'" {
  # `git reset --hard` in the parent does not move submodule checkouts, so the
  # submodule HEAD ends up off the pin with a clean worktree. That is not
  # in-progress work; tell the user the one command that fixes it.
  git -C "$PARENT/sub" commit -q --allow-empty -m local-drift
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" != *"uncommitted changes"* ]]
  [[ "$output" == *"off the pinned commit"* ]]
  [[ "$output" == *"git -C $PARENT submodule update --init"* ]]
}
