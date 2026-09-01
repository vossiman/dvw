#!/usr/bin/env bash
# dvw pin-rebuild, one-stop: resolve the build branch from the source clone,
# PR the stale pin (build branch + main baseline), verify the merge via gh,
# ff-pull the clone, rebuild, and assert the running image. Every step that
# can silently no-op is followed by an assertion; silent no-ops in this chain
# are exactly what shipped stale rebuilds before.
# Spec: docs/superpowers/specs/2026-09-01-pin-rebuild-one-stop-design.md

DVW_PIN_REBUILD_POLL_SECS="${DVW_PIN_REBUILD_POLL_SECS:-10}"

# sha256:<64 hex> component of an image ref; empty output when tag-pinned.
_dvw_pin_digest() {
  [[ "${1:-}" =~ sha256:[0-9a-f]{64} ]] || return 1
  printf '%s\n' "${BASH_REMATCH[0]}"
}

# Poll until the PR is merged. rc 0 merged / 1 timeout or gh failure /
# 2 closed-unmerged. Enter re-checks immediately; Ctrl-C aborts the command.
_dvw_pin_wait_merged() {
  local url="$1" timeout="${2:-1800}" waited=0 state
  ui_info "waiting for merge (Enter re-checks, Ctrl-C aborts): $url"
  while :; do
    state=$(gh pr view "$url" --json state --jq '.state' 2>/dev/null) || state=""
    case "$state" in
      MERGED) return 0 ;;
      CLOSED) ui_error "PR closed without merging: $url"; return 2 ;;
    esac
    (( waited >= timeout )) && { ui_error "timed out after ${timeout}s: $url"; return 1; }
    read -r -t "$DVW_PIN_REBUILD_POLL_SECS" _ 2>/dev/null || true
    waited=$(( waited + DVW_PIN_REBUILD_POLL_SECS ))
  done
}

# Baseline PR against main so future workspaces start current. Never blocks:
# skipped when main is the build branch, already current, or unpinned; a
# failure is a warning, not an error.
_dvw_pin_main_pr() {
  local slug="$1" branch="$2" bp="$3" cur url
  [[ "$branch" == "main" ]] && return 0
  cur=$(_dvw_repo_pin "$slug" main) || {
    ui_status_warn "couldn't read main's pin; skipping the baseline PR"; return 0; }
  [[ -z "$cur" || "$cur" == "$bp" ]] && return 0
  if url=$(_dvw_pin_open_pr "$slug" main "$bp"); then
    [[ -n "$url" ]] && ui_status_ok "baseline PR (main): $url"
  else
    ui_status_warn "couldn't open the baseline PR against main (not blocking)"
  fi
  return 0
}

cmd_pin_rebuild() {
  local id="" timeout=1800 no_wait=0
  while (($#)); do
    case "$1" in
      --no-wait) no_wait=1 ;;
      --timeout) shift; timeout="${1:-1800}" ;;
      -*) ui_error "unknown flag: $1"; return 1 ;;
      *)
        if [[ -n "$id" ]]; then
          ui_error "usage: dvw pin-rebuild <workspace-id> [--no-wait] [--timeout <s>]"
          return 1
        fi
        id="$1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || {
    ui_error "usage: dvw pin-rebuild <workspace-id> [--no-wait] [--timeout <s>]"
    return 1; }
  command -v gh >/dev/null 2>&1 || {
    ui_error "pin-rebuild needs the gh CLI (it opens and watches the PR)"
    return 1; }

  local ws repo slug bp
  ws=$(catalog_workspace_get "$id") || { ui_error "unknown workspace: $id"; return 1; }
  repo=$(jq -r '.repo // empty' <<<"$ws")
  slug=$(_dvw_repo_slug "$repo") || {
    ui_error "$id: $repo is not a GitHub repo; pin-rebuild cannot PR it"; return 1; }
  bp=$(_dvw_blueprint_pin) || {
    ui_error "couldn't read the blueprint pin from $DVW_BLUEPRINT_DEVCONTAINER_URL"
    return 1; }

  # 1. Build branch = the source clone's live HEAD; that is literally what
  #    `devpod up --recreate` reads. Catalog branch only as a warned fallback.
  local src branch committed
  if src=$(_dvw_catalog_source_get "$id" 2>/dev/null); then
    [[ $(jq -r '.present' <<<"$src") == "true" ]] || {
      ui_error "$id: no source clone on the provider; has devpod ever built it?"
      return 1; }
    [[ $(jq -r '.detached' <<<"$src") == "true" ]] && {
      ui_error "$id: source clone is on a detached HEAD; check out a branch first"
      return 1; }
    branch=$(jq -r '.branch // empty' <<<"$src")
    committed=$(jq -r '.committed_pin // empty' <<<"$src")
  else
    branch=$(jq -r '.branch // empty' <<<"$ws")
    committed=""
    ui_status_warn "catalog service unreachable; falling back to catalog branch '$branch' (unverified; the pull step will fail without the service)"
  fi
  [[ -n "$branch" ]] || { ui_error "$id: couldn't resolve a build branch"; return 1; }

  ui_banner "dvw pin-rebuild" "$id, $slug@$branch → $(_dvw_pin_short "$bp")"

  # 2+3. PR only when the working tree's pin differs. When it is already
  # current there is nothing to merge or pull; go straight to the rebuild
  # (the container may still be running the old image).
  local pr_url="" need_sync=0
  if [[ "$committed" == "$bp" ]]; then
    ui_status_ok "committed pin already current on $branch; skipping PR and pull"
  else
    need_sync=1
    ui_action "stale" "$branch pins $(_dvw_pin_short "${committed:-<none>}")"
    pr_url=$(_dvw_pin_open_pr "$slug" "$branch" "$bp") || {
      ui_error "couldn't open the pin PR for $slug@$branch"; return 1; }
    [[ -n "$pr_url" ]] && ui_status_ok "PR: $pr_url"
    _dvw_pin_main_pr "$slug" "$branch" "$bp"
  fi

  if (( need_sync )) && [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would wait for the merge, pull the source clone, rebuild $id, and verify the image"
    return 0
  fi

  if (( need_sync )); then
    # 4. Merge gate, verified via gh; the user's say-so is not an input.
    if [[ -n "$pr_url" ]]; then
      if (( no_wait )); then
        ui_info "--no-wait: merge the PR, then re-run: dvw pin-rebuild $id"
        return 0
      fi
      _dvw_pin_wait_merged "$pr_url" "$timeout" || return $?
      ui_status_ok "merged: $pr_url"
    fi

    # 5. Pull the clone; devpod builds from its working tree.
    local pull_body rc=0
    pull_body=$(_dvw_catalog_source_pull "$id") || rc=$?
    if (( rc != 0 )); then
      local detail
      detail=$(jq -r '.detail // .error // empty' <<<"$pull_body" 2>/dev/null)
      ui_error "couldn't pull the source clone${detail:+: $detail}"
      return 1
    fi
    ui_status_ok "source clone pulled"

    # 6. Assert the working tree now carries the blueprint pin. This is the
    #    assertion that catches a merge that landed somewhere the clone
    #    doesn't point.
    committed=$(jq -r '.committed_pin // empty' <<<"$pull_body")
    if [[ "$committed" != "$bp" ]]; then
      ui_error "after the pull, $branch's working tree still pins $(_dvw_pin_short "${committed:-<none>}"), expected $(_dvw_pin_short "$bp")"
      ui_info "  did the PR target the branch the clone has checked out?"
      return 1
    fi
    ui_status_ok "working tree pin verified"
  fi

  # Dry-run for the already-current path (the stale path returned above).
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would rebuild $id and verify the image"
    return 0
  fi

  # 7. Rebuild. Skip recreate's own preflight; this command IS the preflight.
  DVW_SKIP_PIN_PREFLIGHT=1 cmd_recreate "$id" || return 1

  # 8. Assert the running image.
  local bp_digest digest insp
  if ! bp_digest=$(_dvw_pin_digest "$bp"); then
    ui_status_warn "blueprint pin is not digest-pinned; cannot verify the running image"
    return 0
  fi
  insp=$(_catalog_req GET "/v1/workspaces/$id/inspect" 2>/dev/null) || insp=""
  digest=$(jq -r '.image_digest // empty' <<<"$insp" 2>/dev/null) || digest=""
  if [[ -z "$digest" ]]; then
    ui_status_warn "couldn't read the rebuilt container's image digest; verify manually: dvw status"
    return 0
  fi
  if [[ "$digest" == "$bp_digest" ]]; then
    ui_status_ok "$id is running the blueprint image ($(_dvw_pin_short "$bp"))"
    return 0
  fi
  ui_status_fail "$id rebuilt onto ${digest:0:19}… but the blueprint is ${bp_digest:0:19}…"
  return 1
}
