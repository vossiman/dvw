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
# This is the ONLY thing that closes the loop: it runs when you ask it to,
# because the badge is up and you want it fixed now. A bot raising a PR per
# repo on a cron was considered and rejected (unwanted PR noise, user decision
# 2026-08-20). The dvw catalog is the workspace registry, so consumer
# discovery is free — no GitHub topic, no hand-kept list, no cross-repo PAT.

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
#
# The distinction matters (review 2026-08-21): collapsing every gh failure
# into rc 0 classified transient network/auth/rate-limit errors as "unpinned",
# which preflight silently passed. Only HTTP 404 means the file genuinely
# isn't there; anything else is unknown.
_dvw_repo_pin() {
  local slug="$1" branch="$2" body errfile rc=0
  errfile=$(mktemp) || return 1
  body=$(gh api "repos/$slug/contents/.devcontainer/devcontainer.json?ref=$branch" \
           --jq '.content' 2>"$errfile") || rc=$?
  if (( rc != 0 )); then
    if grep -qi '404\|Not Found' "$errfile"; then
      rm -f "$errfile"
      return 0
    fi
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  printf '%s' "$body" | tr -d '\n' | base64 -d 2>/dev/null \
    | jq -r '.image // empty' 2>/dev/null || return 1
}

# Source-clone state / ff-pull via the catalog service. Print the JSON body;
# rc per _catalog_req (2 = unreachable, 1 = HTTP error).
_dvw_catalog_source_get()  { _catalog_req GET  "/v1/workspaces/$1/source"; }
_dvw_catalog_source_pull() { _catalog_req POST "/v1/workspaces/$1/source/pull"; }

# 12-char digest for display; falls back to the whole ref for non-digest pins.
_dvw_pin_short() {
  local ref="$1"
  case "$ref" in
    *@sha256:*) printf '%.12s\n' "${ref##*@sha256:}" ;;
    *)          printf '%s\n' "$ref" ;;
  esac
}

# Head branch name for a pin PR against <base> moving the pin to <image>.
# One head branch per base: a shared head cannot carry different bases' file
# rewrites (the second PUT 409s on the first PUT's blob, since it reuses the
# other base's content sha). main keeps the historical name (no suffix) so
# existing open PRs are still recognized.
_dvw_pin_head_branch() {
  local base="$1" image="$2"
  local branch="$DVW_PIN_BRANCH_PREFIX-$(_dvw_pin_short "$image")"
  local base_slug="${base//\//-}"
  [[ "$base" != "main" ]] && branch="$branch-$base_slug"
  printf '%s\n' "$branch"
}

# Open (or report) the pin PR for <slug>@<base>, moving the pin to <image>.
# Idempotent: an existing open PR from our branch is reported, not duplicated.
# Prints the PR URL on success.
_dvw_pin_open_pr() {
  local slug="$1" base="$2" image="$3"
  local branch
  branch=$(_dvw_pin_head_branch "$base" "$image")
  local existing meta sha head tmp url orig target_line

  existing=$(gh pr list -R "$slug" --head "$branch" --state open \
               --json url --jq '.[0].url // empty' 2>/dev/null) || existing=""
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"; return 0
  fi

  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would open $slug PR $branch -> $base pinning $(_dvw_pin_short "$image")" >&2
    return 0
  fi

  meta=$(gh api "repos/$slug/contents/.devcontainer/devcontainer.json?ref=$base" 2>/dev/null) || return 1
  sha=$(jq -r '.sha' <<<"$meta") || return 1
  tmp=$(mktemp) || return 1
  orig=$(mktemp) || { rm -f "$tmp"; return 1; }
  jq -r '.content' <<<"$meta" | tr -d '\n' | base64 -d > "$tmp" 2>/dev/null \
    || { rm -f "$tmp" "$orig"; return 1; }
  cp "$tmp" "$orig"
  # Rewrite the complete image property, not a tag/digest suffix selected
  # from the NEW ref. The latter could handle tag->tag and digest->digest but
  # still failed the real migration: an existing tag moving to the blueprint's
  # digest. Replacing the quoted value handles both directions, nested/dotted
  # repository names, and an existing ref with or without a registry prefix,
  # while preserving JSONC comments and all surrounding formatting.
  [[ "$image" =~ ^[A-Za-z0-9._:/@-]+$ ]] || {
    rm -f "$tmp" "$orig"
    ui_error "$slug: blueprint image ref contains unsupported characters"
    return 1
  }
  local esc_image="$image"
  esc_image="${esc_image//\\/\\\\}"
  esc_image="${esc_image//&/\\&}"
  esc_image="${esc_image//|/\\|}"
  # Rewrite the value on the first *real* image property — one that is not
  # inside a `/* */` block or after a `//` line comment. Anchoring sed on
  # `"image"` alone rewrote a commented-out example instead, leaving the real
  # pin stale while the changed file reported success (review 2026-08-24). awk
  # tracks comment state (POSIX; no backrefs) to pick the line; sed then does
  # the proven quoted-value replacement on exactly that line.
  target_line=$(awk '
    BEGIN { inblock = 0 }
    {
      code = $0
      gsub(/\/\*[^*]*\*+([^/*][^*]*\*+)*\//, "", code)   # same-line /* ... */
      if (inblock) {
        if (match(code, /\*\//)) { code = substr(code, RSTART + RLENGTH); inblock = 0 }
        else { code = "" }
      }
      if (match(code, /\/\*/)) { code = substr(code, 1, RSTART - 1); inblock = 1 }
      sub(/\/\/.*/, "", code)                            # // line comment
      if (code ~ /"image"[[:space:]]*:/) { print NR; exit }
    }' "$tmp")
  if [[ -n "$target_line" ]]; then
    sed -i -E "${target_line}s|(\"image\"[[:space:]]*:[[:space:]]*\")[^\"]+\"|\1${esc_image}\"|" "$tmp"
  fi
  # Whatever the strategy: a byte-identical result would PUT nothing and open
  # an empty PR — report that honestly instead.
  if cmp -s "$tmp" "$orig"; then
    rm -f "$tmp" "$orig"
    ui_error "$slug: couldn't rewrite the image property in place (unexpected format) — needs a manual update"
    return 1
  fi
  # Do not run jq over the decoded file here: devcontainer.json is JSONC and
  # real repositories legitimately carry comments. The constrained ref above
  # plus the quoted-value replacement cannot introduce JSON/JSONC syntax.
  rm -f "$orig"

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

# _dvw_pin_state <id> [<blueprint-pin>] — prints
# "<state>\t<slug>\t<branch>\t<current>" where state is ok | stale | none |
# unknown. Never fails the caller. Passing the blueprint pin skips a redundant
# fetch per workspace (cmd_pin_sync already resolved it once).
_dvw_pin_state() {
  local id="$1" bp_arg="${2:-}" ws repo branch slug cur bp
  ws=$(catalog_workspace_get "$id" 2>/dev/null) || { printf 'unknown\t\t\t\n'; return 0; }
  repo=$(jq -r '.repo // empty' <<<"$ws"); branch=$(jq -r '.branch // empty' <<<"$ws")
  slug=$(_dvw_repo_slug "$repo") || { printf 'unknown\t%s\t%s\t\n' "$repo" "$branch"; return 0; }
  [[ -n "$branch" ]] || { printf 'unknown\t%s\t\t\n' "$slug"; return 0; }

  # The clone's live branch is what `devpod up --recreate` builds from; the
  # catalog records only the creation-time branch. Fail-open to the catalog
  # value: unreachable service, absent clone, or detached HEAD change nothing.
  local src live
  if src=$(_dvw_catalog_source_get "$id" 2>/dev/null); then
    live=$(jq -r 'select(.present == true and .detached == false)
                  | .branch // empty' <<<"$src" 2>/dev/null) || live=""
    [[ -n "$live" ]] && branch="$live"
  fi
  if [[ -z "$bp_arg" ]]; then
    bp=$(_dvw_blueprint_pin) || { printf 'unknown\t%s\t%s\t\n' "$slug" "$branch"; return 0; }
  else
    bp="$bp_arg"
  fi
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
    # Not `mapfile < <(...)`: a failing catalog in the process substitution
    # fed mapfile nothing and the run "succeeded" with 0/0/0 (review
    # 2026-08-21). Discovery failure must fail the command.
    local ids_raw
    ids_raw=$(catalog_workspace_ids) || {
      ui_error "couldn't list catalog workspaces — pin-sync cannot know what to sync"
      return 1
    }
    mapfile -t ids <<<"$ids_raw"
  fi

  ui_banner "dvw pin-sync" "blueprint: $(_dvw_pin_short "$bp")"

  local id line state slug branch cur url n_stale=0 n_ok=0 n_skip=0 n_fail=0
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    line=$(_dvw_pin_state "$id" "$bp")
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
          n_fail=$((n_fail + 1))
        fi ;;
      *)
        ui_status_warn "$id — couldn't determine the pin (not a GitHub repo, or lookup failed)"
        n_skip=$((n_skip + 1)) ;;
    esac
  done

  printf '\n'
  ui_info "$n_ok current · $n_stale stale · $n_skip skipped"
  [[ $n_stale -gt 0 ]] && ui_info "merge the PRs, then: dvw rebuild <id>"
  # Automation reads the exit status: every PR failing while the command
  # returns 0 made unattended runs look healthy (review 2026-08-21).
  (( n_fail > 0 )) && return 1
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
    ui_info "merge the PR, then: dvw pin-rebuild $id (pulls the source clone and verifies the image)"
    return 1
  fi
  return 0
}
