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
