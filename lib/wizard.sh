#!/usr/bin/env bash
# Wizard for creating a new DevPod workspace.

# Sanitize a string for use as a workspace ID: lowercase alnum + dash.
_sanitize_ws_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9-]+#-#g; s#^-+|-+$##g'
}

# Extract the leaf name from a git URL (e.g., git@github.com:foo/bar.git -> bar).
_repo_leaf() {
  echo "$1" | sed -E 's#.*[/:]([^/:]+?)(\.git)?$#\1#'
}

# Parse `git ls-remote --heads` output (on stdin) into a sorted list of branch
# names, stripping the leading "<sha>\trefs/heads/" from each line. Pure (no
# network) so the branch flow's only testable part can be unit-tested.
_parse_remote_branches() {
  sed -E 's#^[0-9a-f]+[[:space:]]+refs/heads/##' | LC_ALL=C sort
}

# Convert an HTTPS github.com URL to its SSH equivalent; echo anything else
# unchanged. github.com only — in the devbox git authenticates github over the
# forwarded ssh-agent, so an HTTPS clone has no credential helper and ls-remote
# dies with "exit status 128". The transform drops any userinfo/token and
# normalizes to a single .git suffix. Pure (no network) → unit-testable.
_github_https_to_ssh() {
  local url="$1"
  case "$url" in
    https://github.com/*|https://*@github.com/*)
      url=$(printf '%s\n' "$url" \
        | sed -E 's#^https://([^@/]+@)?github\.com/#git@github.com:#; s#(\.git)?$#.git#')
      ;;
  esac
  printf '%s\n' "$url"
}

# Fetch + parse a repo's remote branch names; echo one branch per line, or
# nothing on failure (auth/network/bad URL) OR an empty repo. RETURNS git's
# ls-remote exit status so callers can tell "reachable but empty" (rc 0, no
# output → a freshly-created repo) from "failed" (rc != 0). Call it as
# `if branches=$(_fetch_remote_branches "$r"); then rc=0; else rc=$?; fi`:
# the `if` both captures the branch list AND reads the rc, and crucially keeps
# git's 128-over-HTTPS (no credential helper under the script's `set -e`) from
# aborting the whole wizard before the empty-result handling can run. (A global
# can't carry the rc — this runs in the `$(...)` subshell, so it wouldn't
# propagate.)
_fetch_remote_branches() {
  local repo="$1" raw rc
  if raw=$(GIT_TERMINAL_PROMPT=0 gum spin --spinner dot \
             --title "fetching branches for $repo..." --show-output \
             -- git ls-remote --heads "$repo" 2>/dev/null); then
    rc=0
  else
    rc=$?
    raw=""
  fi
  printf '%s\n' "$raw" | _parse_remote_branches
  return "$rc"
}

# Seed an empty remote with an initial empty commit on <branch> (default main)
# so the wizard has something to clone. Pushes over the URL as-is — callers pass
# the SSH form for github so auth works. Uses the caller's git identity, falling
# back to a generic one so the commit succeeds even where git user.* is unset.
# Side-effecting (creates a commit, pushes); returns non-zero if init or push
# fails. The work happens in a throwaway temp dir that is always cleaned up.
_init_empty_repo() {
  local repo="$1" branch="${2:-main}" tmp rc name email
  name=$(git config --get user.name 2>/dev/null || true);  [[ -n "$name" ]]  || name="dvw"
  email=$(git config --get user.email 2>/dev/null || true); [[ -n "$email" ]] || email="dvw@localhost"
  tmp=$(mktemp -d) || return 1
  (
    cd "$tmp" \
      && git init -q -b "$branch" \
      && git -c user.name="$name" -c user.email="$email" commit -q --allow-empty -m "init" \
      && git remote add origin "$repo" \
      && GIT_TERMINAL_PROMPT=0 git push -q -u origin "$branch"
  )
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# Print one workspace ID per line from `devpod list --output json` output read
# on stdin. Pure (no devpod call) so the wizard's collision check is testable.
_parse_devpod_ids() {
  jq -r '.[].id' 2>/dev/null
}

# DevPod's hard cap on workspace IDs (it errors out with "workspace name
# cannot be longer than N characters" at `devpod up` time). Branches like
# `design/dvw-extract-and-multi-agent` produce defaults that blow past this
# unless we clip up front.
DEVPOD_NAME_MAX=48

# Truncate to fit DevPod's name length cap; trim any trailing dash left by
# the cut so the result is still a clean valid identifier. Idempotent on
# names already short enough.
_truncate_for_devpod() {
  local name="$1"
  local max="${2:-$DEVPOD_NAME_MAX}"
  if (( ${#name} > max )); then
    name="${name:0:max}"
    name="${name%-}"
  fi
  echo "$name"
}

cmd_new() {
  command -v gum >/dev/null || { ui_error "gum not installed; run dvw doctor"; return 1; }
  command -v devpod >/dev/null || { ui_error "devpod not installed; run dvw doctor"; return 1; }

  ui_banner "new workspace" "wizard creates a workspace, brings the container up, and adds it to the catalog"

  # 1. Repo
  local repos repo
  repos=$(catalog_repo_list)
  if [[ -z "$repos" ]]; then
    repo=$(gum input --placeholder "git@github.com:owner/repo.git" --header "repo URL" \
            --header.foreground "$DVW_SUBTLE")
  else
    repo=$(printf "+ enter new...\n%s\n" "$repos" \
      | gum filter --placeholder "pick a repo (or '+ enter new...')")
    if [[ "$repo" == "+ enter new..." || -z "$repo" ]]; then
      repo=$(gum input --placeholder "git@github.com:owner/repo.git" --header "repo URL" \
              --header.foreground "$DVW_SUBTLE")
    fi
  fi
  [[ -z "$repo" ]] && { ui_info "aborted: no repo"; return 1; }

  # 2. Branch — pick from the repo's live remote branches. Listing only what
  # actually exists rules out stale catalog defaults and typo'd/deleted
  # branches, which `devpod up` would otherwise reject mid-clone with an
  # opaque "exit status 128".
  local branches branch rc=0
  if branches=$(_fetch_remote_branches "$repo"); then rc=0; else rc=$?; fi
  if [[ -z "$branches" && $rc -ne 0 ]]; then
    # An HTTPS github.com URL has no credential helper in the devbox (auth is
    # the forwarded ssh-agent), so ls-remote dies with 128. Derive the SSH form
    # and retry once before giving up; on a reachable result switch to it so the
    # catalog records the URL that actually works here.
    local ssh_repo
    ssh_repo=$(_github_https_to_ssh "$repo")
    if [[ "$ssh_repo" != "$repo" ]]; then
      ui_info "HTTPS clone needs credentials we don't have here; retrying via SSH: $ssh_repo"
      if branches=$(_fetch_remote_branches "$ssh_repo"); then rc=0; else rc=$?; fi
      [[ $rc -eq 0 ]] && repo="$ssh_repo"
    fi
  fi
  if [[ -z "$branches" && $rc -ne 0 ]]; then
    ui_error "couldn't list branches for $repo — check the URL, your network, or SSH auth"
    return 1
  fi
  if [[ -z "$branches" ]]; then
    # rc == 0 but zero refs → the repo is reachable but empty (freshly created,
    # no commits). Offer to seed it with an initial commit so there's a branch
    # to clone, rather than dead-ending on "couldn't list branches".
    ui_status_warn "repo is empty — it has no branches yet: $repo"
    gum confirm "Create an initial commit on 'main' and push?" \
      || { ui_info "aborted: empty repo not initialized"; return 1; }
    ui_action "initializing" "$repo (empty commit on main)"
    if ! _init_empty_repo "$repo" main; then
      ui_error "failed to initialize empty repo: $repo — check your push access"
      return 1
    fi
    ui_status_ok "initialized $repo with an empty commit on 'main'"
    branch="main"
  else
    branch=$(printf '%s\n' "$branches" | gum filter --placeholder "pick a branch")
  fi
  [[ -z "$branch" ]] && { ui_info "aborted: no branch"; return 1; }

  # 3. Workspace name (DevPod caps these at DEVPOD_NAME_MAX chars).
  local default_name name
  default_name=$(_sanitize_ws_name "$(_repo_leaf "$repo")-$branch")
  default_name=$(_truncate_for_devpod "$default_name")
  name=$(gum input --value "$default_name" \
          --header "workspace name (max $DEVPOD_NAME_MAX chars)" \
          --char-limit "$DEVPOD_NAME_MAX" \
          --header.foreground "$DVW_SUBTLE")
  name=$(_sanitize_ws_name "$name")
  [[ -z "$name" ]] && { ui_info "aborted: no name"; return 1; }
  if (( ${#name} > DEVPOD_NAME_MAX )); then
    # Defensive: --char-limit should prevent this, but older gum versions
    # don't enforce it, and _sanitize_ws_name (tr+sed substitutions) can in
    # theory expand length. Reject before invoking devpod up.
    ui_error "workspace name too long (${#name} chars, max $DEVPOD_NAME_MAX): $name"
    return 1
  fi
  if catalog_workspace_get "$name" >/dev/null 2>&1; then
    ui_error "workspace ID already exists in catalog: $name"
    return 1
  fi
  # A name that already exists in DevPod's own store — even when absent from the
  # catalog — is a trap: `devpod up <repo>@<branch> --id <name>` against an
  # existing workspace SILENTLY reuses that workspace's pinned source/branch and
  # ignores the @branch we pass. The user's branch pick gets thrown away and the
  # clone runs against whatever (possibly stale, now-deleted) branch the
  # workspace was first created with — failing with an opaque "exit status 128".
  # Refuse up front rather than hand devpod a colliding name.
  if command -v devpod >/dev/null 2>&1; then
    local existing_ids
    existing_ids=$(devpod list --output json 2>/dev/null | _parse_devpod_ids)
    if printf '%s\n' "$existing_ids" | grep -qxF -- "$name"; then
      ui_error "workspace already exists in DevPod: $name"
      ui_info "(\`devpod up --id $name\` would reuse its original branch and ignore your pick \"$branch\")"
      ui_info "remove it first (dvw rm $name, or devpod delete $name), or choose a different name"
      return 1
    fi
  fi

  # 4. IDE
  local default_ide ide
  default_ide=$(catalog_default ide)
  default_ide="${default_ide:-cursor}"
  ide=$(gum choose \
          --selected "$default_ide" \
          --cursor "❯ " \
          --cursor.foreground "$DVW_ACCENT" \
          --selected.foreground "$DVW_ACCENT" \
          --header.foreground "$DVW_SUBTLE" \
          --header "IDE" \
          cursor ssh)
  [[ -z "$ide" ]] && { ui_info "aborted: no ide"; return 1; }

  # 5. Confirm — show a styled summary box.
  local devpod_ide="$ide"
  [[ "$ide" == "ssh" ]] && devpod_ide="none"
  echo
  gum style \
    --border rounded --padding "0 2" --margin "0 0 1 0" \
    --foreground "$DVW_SUBTLE" --border-foreground "$DVW_ACCENT" \
    "$(printf 'repo    %s\nbranch  %s\nname    %s\nIDE     %s' \
        "$repo" "$branch" "$name" "$ide")"
  gum confirm "Create workspace?" || { ui_info "aborted"; return 1; }

  # 6. Run devpod up
  ui_action "creating" "$name (ide=$devpod_ide)"
  if ! devpod up "${repo}@${branch}" --id "$name" --ide "$devpod_ide"; then
    ui_error "devpod up failed; catalog not modified"
    # devpod registers the workspace entry (pinned to this @branch) BEFORE it
    # clones, so a failed clone leaves an orphan behind. Left in place, that
    # orphan poisons the next attempt: `devpod up --id <name>` would reuse its
    # pinned branch and ignore the branch picked next time. We verified the name
    # was free at the top of this run, so the entry is ours — remove it so the
    # next `dvw new` starts clean.
    if devpod list --output json 2>/dev/null | _parse_devpod_ids | grep -qxF -- "$name"; then
      ui_info "cleaning up partially-created workspace: $name"
      devpod delete "$name" --force --ignore-not-found >/dev/null 2>&1 \
        || ui_status_warn "could not remove partial workspace $name (remove with: devpod delete $name)"
    fi
    return 1
  fi

  # 7. Update catalog
  local provider host
  provider=$(catalog_default provider)
  provider="${provider:-${DVW_PROVIDER:-vossisrv}}"
  host=$(hostname -s)
  catalog_workspace_add "$name" "$repo" "$branch" "$ide" "$provider" "$host"
  catalog_repo_upsert "$repo" "$branch"
  # Snapshot devpod's local workspace.json (carries the uid that binds the
  # workspace ID to the remote agent dir + dind volumes) into the catalog so
  # other machines can synthesize their local devpod state without re-running
  # `devpod up <repo>@<branch>` (which provisions a fresh workspace and
  # destroys the existing remote one).
  if ! catalog_workspace_set_devpod_state "$name"; then
    ui_status_warn "could not snapshot devpod state for $name into catalog (next \`dvw $name\` will retry)"
  fi
  printf '%s✓%s added to catalog: %s%s%s\n' \
    "$(_ansi "$DVW_GREEN" bold)" "$(ui_reset)" \
    "$(_ansi "$DVW_ACCENT" bold)" "$name" "$(ui_reset)"
}
