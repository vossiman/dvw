#!/usr/bin/env bash
# dvw pin-sync — reconcile each workspace repo's committed devcontainer image
# pin against the aiCodingBaseSetup blueprint, via a PR per repo.
#
# Why this exists: `aicoding-sync` rewrites .devcontainer/devcontainer.json in
# the *container working tree* on every boot but deliberately never commits it
# (aiCodingBaseSetup docs/superpowers/specs/2026-08-09-sync-workspace-pin-design.md
# §6). Nothing else committed it either, so repo copies drifted: on 2026-08-20
# eight workspace repos were still pinned to the 2026-08-09 digest while
# 2026-08-12 was current. `devpod up --recreate` builds from the *committed*
# pin, so `dvw rebuild` kept reinstalling the stale image and the ⬆rebuild
# badge never cleared.
#
# Renovate now covers this on a weekly cron in the workspace repos; this
# command is the on-demand path for "the badge is up and I want it fixed now".
# The dvw catalog is the workspace registry, so consumer discovery is free —
# no GitHub topic, no hand-kept list, no cross-repo PAT.

DVW_PIN_BRANCH_PREFIX="${DVW_PIN_BRANCH_PREFIX:-chore/pin-devbox-base}"

# Blueprint pin (the source of truth). Reuses wizard.sh's fetch so both paths
# read the same URL and honor the same test override. Prints the image ref;
# non-zero on fetch failure or a devcontainer.json with no image.
_dvw_blueprint_pin() {
  local tmp image rc=0
  tmp=$(mktemp) || return 1
  if ! _fetch_blueprint_devcontainer "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  image=$(jq -r '.image // empty' "$tmp" 2>/dev/null) || rc=1
  rm -f "$tmp"
  [[ -n "$image" && $rc -eq 0 ]] || return 1
  printf '%s\n' "$image"
}

# owner/name from either remote form the fleet uses (SSH on hosts, HTTPS in
# containers — see devMachine CLAUDE.md "git auth in the devbox"). Non-GitHub
# remotes return non-zero: the gh-based PR path cannot serve them.
_dvw_repo_slug() {
  local repo="$1" slug
  case "$repo" in
    git@github.com:*)          slug="${repo#git@github.com:}" ;;
    https://github.com/*)      slug="${repo#https://github.com/}" ;;
    ssh://git@github.com/*)    slug="${repo#ssh://git@github.com/}" ;;
    github.com/*)              slug="${repo#github.com/}" ;;
    *)                         slug="$repo" ;;   # maybe already owner/name
  esac
  slug="${slug%.git}"
  # Exactly owner/name, no scheme and no host component. Without this a
  # gitlab/codeberg remote would fall through as "gitlab.com/owner/name" and
  # every gh call against it would fail with a confusing 404.
  [[ "$slug" == *://* ]] && return 1
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  [[ "${slug%%/*}" == *.* ]] && return 1
  printf '%s\n' "$slug"
}

# Committed pin of <slug>@<branch>. Empty output + rc 0 means "no devcontainer
# image there" (nothing to sync); rc 1 means the lookup itself failed.
_dvw_repo_pin() {
  local slug="$1" branch="$2" body
  body=$(gh api "repos/$slug/contents/.devcontainer/devcontainer.json?ref=$branch" \
           --jq '.content' 2>/dev/null) || return 0
  printf '%s' "$body" | tr -d '\n' | base64 -d 2>/dev/null \
    | jq -r '.image // empty' 2>/dev/null || return 1
}

# 12-char digest for display; falls back to the whole ref for non-digest pins.
_dvw_pin_short() {
  local ref="$1"
  case "$ref" in
    *@sha256:*) printf '%.12s\n' "${ref##*@sha256:}" ;;
    *)          printf '%s\n' "$ref" ;;
  esac
}

# Open (or report) the pin PR for <slug>@<base>, moving the pin to <image>.
# Idempotent: an existing open PR from our branch is reported, not duplicated.
# Prints the PR URL on success.
_dvw_pin_open_pr() {
  local slug="$1" base="$2" image="$3"
  local branch="$DVW_PIN_BRANCH_PREFIX-$(_dvw_pin_short "$image")"
  local existing meta sha head tmp url

  existing=$(gh pr list -R "$slug" --head "$branch" --state open \
               --json url --jq '.[0].url // empty' 2>/dev/null) || existing=""
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"; return 0
  fi

  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would open $slug PR $branch -> $base pinning $(_dvw_pin_short "$image")"
    return 0
  fi

  meta=$(gh api "repos/$slug/contents/.devcontainer/devcontainer.json?ref=$base" 2>/dev/null) || return 1
  sha=$(jq -r '.sha' <<<"$meta") || return 1
  tmp=$(mktemp) || return 1
  jq -r '.content' <<<"$meta" | tr -d '\n' | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # Rewrite only the digest inside the existing pin — same format-preserving
  # sed the blueprint's own CI self-pin uses, so comments/ordering survive.
  sed -i -E "s|(ghcr\.io/[^\"@]+@)sha256:[0-9a-f]{64}|\1${image##*@}|" "$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; ui_error "$slug: rewritten devcontainer.json is not valid JSON — skipped"; return 1
  fi

  head=$(gh api "repos/$slug/git/ref/heads/$base" --jq '.object.sha' 2>/dev/null) || { rm -f "$tmp"; return 1; }
  gh api -X POST "repos/$slug/git/refs" -f ref="refs/heads/$branch" -f sha="$head" >/dev/null 2>&1 || true
  gh api -X PUT "repos/$slug/contents/.devcontainer/devcontainer.json" \
    -f message="chore(image): pin devbox-base $(_dvw_pin_short "$image")" \
    -f branch="$branch" -f sha="$sha" -f content="$(base64 -w0 "$tmp")" >/dev/null 2>&1 || {
      rm -f "$tmp"; return 1; }
  rm -f "$tmp"

  url=$(gh pr create -R "$slug" -B "$base" -H "$branch" \
    -t "chore(image): pin devbox-base $(_dvw_pin_short "$image")" \
    -b "Opened by \`dvw pin-sync\`. Moves the committed devcontainer image pin to the blueprint's current digest so \`dvw rebuild\` stops recreating this workspace from a stale image." 2>/dev/null) || return 1
  printf '%s\n' "$url"
}

# _dvw_pin_state <id> — prints "<state>\t<slug>\t<branch>\t<current>" where
# state is ok | stale | none | unknown. Never fails the caller.
_dvw_pin_state() {
  local id="$1" ws repo branch slug cur bp
  ws=$(catalog_workspace_get "$id" 2>/dev/null) || { printf 'unknown\t\t\t\n'; return 0; }
  repo=$(jq -r '.repo // empty' <<<"$ws"); branch=$(jq -r '.branch // empty' <<<"$ws")
  slug=$(_dvw_repo_slug "$repo") || { printf 'unknown\t%s\t%s\t\n' "$repo" "$branch"; return 0; }
  [[ -n "$branch" ]] || { printf 'unknown\t%s\t\t\n' "$slug"; return 0; }
  bp=$(_dvw_blueprint_pin) || { printf 'unknown\t%s\t%s\t\n' "$slug" "$branch"; return 0; }
  cur=$(_dvw_repo_pin "$slug" "$branch") || { printf 'unknown\t%s\t%s\t\n' "$slug" "$branch"; return 0; }
  if [[ -z "$cur" ]]; then
    printf 'none\t%s\t%s\t\n' "$slug" "$branch"
  elif [[ "$cur" == "$bp" ]]; then
    printf 'ok\t%s\t%s\t%s\n' "$slug" "$branch" "$cur"
  else
    printf 'stale\t%s\t%s\t%s\n' "$slug" "$branch" "$cur"
  fi
}

# cmd_pin_sync [<workspace-id>...] — no args = every catalog workspace.
cmd_pin_sync() {
  if ! command -v gh >/dev/null 2>&1; then
    ui_error "pin-sync needs the gh CLI (it opens the PRs)"
    return 1
  fi
  local bp
  if ! bp=$(_dvw_blueprint_pin); then
    ui_error "couldn't read the blueprint pin from $DVW_BLUEPRINT_DEVCONTAINER_URL"
    return 1
  fi

  local ids=()
  if (($# > 0)); then
    ids=("$@")
  else
    mapfile -t ids < <(catalog_workspace_ids) || return 1
  fi

  ui_banner "dvw pin-sync" "blueprint: $(_dvw_pin_short "$bp")"

  local id line state slug branch cur url n_stale=0 n_ok=0 n_skip=0
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    line=$(_dvw_pin_state "$id")
    IFS=$'\t' read -r state slug branch cur <<<"$line"
    case "$state" in
      ok)
        ui_status_ok "$id — $slug@$branch already at $(_dvw_pin_short "$cur")"
        n_ok=$((n_ok + 1)) ;;
      none)
        ui_status_warn "$id — $slug@$branch has no .devcontainer image pin (nothing to sync)"
        n_skip=$((n_skip + 1)) ;;
      stale)
        n_stale=$((n_stale + 1))
        ui_action "stale" "$id — $slug@$branch at $(_dvw_pin_short "$cur")"
        if url=$(_dvw_pin_open_pr "$slug" "$branch" "$bp"); then
          [[ -n "$url" ]] && ui_status_ok "  PR: $url"
        else
          ui_status_fail "  couldn't open the PR for $slug@$branch"
        fi ;;
      *)
        ui_status_warn "$id — couldn't determine the pin (not a GitHub repo, or lookup failed)"
        n_skip=$((n_skip + 1)) ;;
    esac
  done

  printf '\n'
  ui_info "$n_ok current · $n_stale stale · $n_skip skipped"
  [[ $n_stale -gt 0 ]] && ui_info "merge the PRs, then: dvw rebuild <id>"
  return 0
}

# Pre-flight for cmd_recreate: if the workspace's committed pin is stale,
# say so and OFFER pin-sync before we recreate from the old image. Declining
# proceeds with the rebuild — this never blocks. Entirely fail-open: no gh,
# no network, non-GitHub remote → silent pass-through.
_dvw_pin_preflight() {
  local id="$1" line state slug branch cur
  command -v gh >/dev/null 2>&1 || return 0
  line=$(_dvw_pin_state "$id" 2>/dev/null) || return 0
  IFS=$'\t' read -r state slug branch cur <<<"$line"
  [[ "$state" == "stale" ]] || return 0

  ui_status_warn "$slug@$branch is pinned to $(_dvw_pin_short "$cur") — rebuilding now reinstalls that image"
  if ui_confirm "open a pin-sync PR first?"; then
    cmd_pin_sync "$id"
    ui_info "merge the PR, then re-run: dvw rebuild $id"
    return 1
  fi
  return 0
}
