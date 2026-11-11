#!/usr/bin/env bash
# Base-image helpers shared by `dvw recreate` and `dvw pin-rebuild`.
#
# Every workspace devcontainer references the floating :latest tag. The build
# workflow pushes :latest only after its smoke test, so :latest is the newest
# green image. Whether a container runs it is the catalog's image_current
# verdict. (Until 2026-11 some repos still pinned a digest and pin-rebuild
# opened a PR moving them to :latest; that migration is finished.)

DVW_IMAGE_GHCR_REPO="${DVW_IMAGE_GHCR_REPO:-vossiman/devbox-base}"
_dvw_blueprint_pin() { printf 'ghcr.io/%s:latest\n' "$DVW_IMAGE_GHCR_REPO"; }

# Docker never refreshes a tag it already has, so recreate must pull first,
# on the provider's daemon, or it rebuilds onto the cached old :latest.
_dvw_pull_latest() {
  _dvw_run_or_print ssh -o BatchMode=yes -o ConnectTimeout=10 "$DVW_CATALOG_HOST" \
    docker pull -q "$(_dvw_blueprint_pin)"
}

# _dvw_pin_resolve_ids [<workspace-id>...] — the given ids, or every catalog
# workspace when none are given. Prints one id per line.
#
# Not `mapfile < <(...)` at the call site: a failing catalog in the process
# substitution fed mapfile nothing and the run "succeeded" with 0/0/0 (review
# 2026-08-21). Discovery failure must fail the caller.
_dvw_pin_resolve_ids() {
  if (($# > 0)); then
    printf '%s\n' "$@"
    return 0
  fi
  catalog_workspace_ids
}
