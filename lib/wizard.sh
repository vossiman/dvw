#!/usr/bin/env bash
# Wizard for creating a new DevPod workspace.

# Sanitize a string for use as a workspace ID: lowercase alnum + dash.
_sanitize_ws_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9-]+#-#g; s#^-+|-+$##g'
}

# Parse `git ls-remote --heads` output (on stdin) into a sorted list of branch
# names, stripping the leading "<sha>\trefs/heads/" from each line. Pure (no
# network) so the branch flow's only testable part can be unit-tested.
_parse_remote_branches() {
  sed -E 's#^[0-9a-f]+[[:space:]]+refs/heads/##' | LC_ALL=C sort
}

# Convert an HTTPS github.com URL to its SSH equivalent; echo anything else
# unchanged. github.com only. This is a HOST-SIDE PROBE FALLBACK, not the
# workspace URL: since the 2026-06 HTTPS cutover the canonical form is HTTPS
# (see _canonicalize_repo_url), but a client whose only github auth is SSH
# keys (typical desktop) can still ls-remote/seed over this form. The
# transform drops any userinfo/token and normalizes to a single .git suffix.
# Pure (no network) → unit-testable.
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

# Canonicalize a repo reference to the HTTPS github.com URL a new workspace
# should carry. Containers authenticate github over HTTPS (gh helper +
# git-credential-aicoding); an SSH origin cloned into a container has no key
# and no agent, so every later push dies with "Permission denied (publickey)".
# Accepts the SSH forms plus the `owner/name` and `gh:owner/name` shorthands
# the TUI advertises. Anything else (non-github hosts, local paths, an
# `owner/name` that exists as a local path) passes through unchanged. Drops
# userinfo/tokens and normalizes to a single .git suffix. Pure aside from the
# local-path existence check → unit-testable.
_canonicalize_repo_url() {
  local url="$1"
  case "$url" in
    git@github.com:*/*|ssh://git@github.com/*/*|gh:*/*|https://github.com/*|https://*@github.com/*)
      url=$(printf '%s\n' "$url" | sed -E '
        s#^git@github\.com:#https://github.com/#
        s#^ssh://git@github\.com/#https://github.com/#
        s#^gh:#https://github.com/#
        s#^https://([^@/]+@)?github\.com/#https://github.com/#
        s#(\.git)?/?$#.git#')
      ;;
    *)
      if [[ "$url" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && ! -e "$url" ]]; then
        url="https://github.com/${url%.git}.git"
      fi
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
_new_git_ls_remote_heads() {
  git ls-remote --heads "$1" 2>/dev/null
}

_fetch_remote_branches() {
  local repo="$1" raw rc
  if raw=$(GIT_TERMINAL_PROMPT=0 ui_progress "fetching branches for $repo" \
             _new_git_ls_remote_heads "$repo"); then
    rc=0
  else
    rc=$?
    raw=""
  fi
  printf '%s\n' "$raw" | _parse_remote_branches
  return "$rc"
}

# Canonical devcontainer.json of the aiCodingBaseSetup blueprint — the same
# source of truth the blueprint's own postStartCommand pulls from. Overridable
# so tests can point it at a local file:// fixture and stay off the network.
DVW_BLUEPRINT_DEVCONTAINER_URL="${DVW_BLUEPRINT_DEVCONTAINER_URL:-https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/devcontainer.json}"

# Fetch the blueprint devcontainer.json to <dest>. Fails (non-zero) on missing
# curl, network/HTTP errors, or a response that doesn't look like a JSON(C)
# object — the first non-blank line must open with "{", which rejects
# proxy/HTML error pages without outlawing future // comments in the blueprint.
_fetch_blueprint_devcontainer() {
  local dest="$1"
  command -v curl >/dev/null || return 1
  curl -fsSL --max-time 10 "$DVW_BLUEPRINT_DEVCONTAINER_URL" -o "$dest" 2>/dev/null || return 1
  [[ -s "$dest" ]] || return 1
  awk 'NF { print; exit }' "$dest" | grep -q '^[[:space:]]*{' || return 1
}

# Seed an empty remote with an initial commit on <branch> (default main) so the
# wizard has something to clone. The commit carries the blueprint
# devcontainer.json when it can be fetched — the `devpod up` that follows then
# builds the real harness container instead of DevPod's bare default — and
# degrades to an empty commit when it can't (sets DVW_INIT_SEEDED_DEVCONTAINER
# to 1/0 so the caller can word its status line). Pushes over the URL as-is —
# callers pass the SSH form for github so auth works. Uses the caller's git
# identity, falling back to a generic one so the commit succeeds even where git
# user.* is unset. Side-effecting (creates a commit, pushes); returns non-zero
# if init or push fails. The work happens in a throwaway temp dir that is
# always cleaned up.
_init_empty_repo() {
  local repo="$1" branch="${2:-main}" tmp rc name email msg
  name=$(git config --get user.name 2>/dev/null || true);  [[ -n "$name" ]]  || name="dvw"
  email=$(git config --get user.email 2>/dev/null || true); [[ -n "$email" ]] || email="dvw@localhost"
  tmp=$(mktemp -d) || return 1
  DVW_INIT_SEEDED_DEVCONTAINER=0
  msg="init"
  # .devcontainer/devcontainer.json, NOT root devcontainer.json — DevPod only
  # probes .devcontainer/devcontainer.json, .devcontainer.json and
  # .devcontainer/**/devcontainer.json (pkg/devcontainer/config/parse.go); a
  # root-level file is silently ignored and the container builds the bare
  # fallback image (2026-07-14, obsidian-selfhost).
  if mkdir -p "$tmp/.devcontainer" \
      && _fetch_blueprint_devcontainer "$tmp/.devcontainer/devcontainer.json"; then
    DVW_INIT_SEEDED_DEVCONTAINER=1
    msg="init: blueprint devcontainer"
  else
    rm -rf "$tmp/.devcontainer"
  fi
  (
    cd "$tmp" \
      && git init -q -b "$branch" \
      && git add -A \
      && git -c user.name="$name" -c user.email="$email" commit -q --allow-empty -m "$msg" \
      && git remote add origin "$repo" \
      && GIT_TERMINAL_PROMPT=0 git push -q -u origin "$branch"
  )
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# Does <branch> of <repo> carry a devcontainer anywhere DevPod actually looks
# (.devcontainer/devcontainer.json, .devcontainer.json, or
# .devcontainer/**/devcontainer.json)? Returns 0 = present, 1 = missing,
# 2 = couldn't inspect (unreachable repo/branch). Probes via a bare, shallow,
# blobless clone in a throwaway dir — tree objects only, so it stays cheap
# even for blob-heavy repos (the use case is Obsidian vaults); on transports
# without filter support git degrades to a full fetch with a warning.
_branch_has_devcontainer() {
  local repo="$1" branch="$2" tmp rc
  tmp=$(mktemp -d) || return 2
  if ! git clone -q --bare --depth 1 --no-tags --single-branch --branch "$branch" \
        --filter=blob:none "$repo" "$tmp/probe.git" 2>/dev/null; then
    rm -rf "$tmp"
    return 2
  fi
  if git --git-dir "$tmp/probe.git" ls-tree -r --name-only HEAD 2>/dev/null \
      | grep -Eq '^\.devcontainer\.json$|^\.devcontainer/([^/]+/)*devcontainer\.json$'; then
    rc=0
  else
    rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

# Commit the blueprint devcontainer.json as .devcontainer/devcontainer.json on
# <branch> of <repo> and push, so the `devpod up` that follows clones a repo
# that builds the real harness container. Same identity policy as
# _init_empty_repo (host git user.*, generic fallback). Fails without touching
# the remote when the blueprint fetch fails. The clone is shallow, blobless
# and --no-checkout; --no-checkout leaves the index EMPTY (committing straight
# away would produce a tree containing only the devcontainer and wipe the
# branch), so read-tree HEAD first — index becomes HEAD's tree, we add the one
# new file, and the commit is HEAD plus the devcontainer with no other blob
# ever downloaded or rewritten.
_seed_devcontainer_on_branch() {
  local repo="$1" branch="$2" tmp rc name email
  name=$(git config --get user.name 2>/dev/null || true);  [[ -n "$name" ]]  || name="dvw"
  email=$(git config --get user.email 2>/dev/null || true); [[ -n "$email" ]] || email="dvw@localhost"
  tmp=$(mktemp -d) || return 1
  if ! _fetch_blueprint_devcontainer "$tmp/devcontainer.json"; then
    rm -rf "$tmp"
    return 1
  fi
  (
    cd "$tmp" \
      && git clone -q --depth 1 --no-tags --single-branch --branch "$branch" \
           --filter=blob:none --no-checkout "$repo" clone 2>/dev/null \
      && cd clone \
      && git read-tree HEAD \
      && mkdir -p .devcontainer \
      && mv ../devcontainer.json .devcontainer/devcontainer.json \
      && git add .devcontainer/devcontainer.json \
      && git -c user.name="$name" -c user.email="$email" commit -q -m "seed: blueprint devcontainer" \
      && GIT_TERMINAL_PROMPT=0 git push -q origin "HEAD:$branch"
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

_new_usage() {
  ui_info "usage: dvw new --repo <url> --name <name> [--branch <b>] [--ide ssh|cursor] [--init-empty] [--seed-devcontainer] [--yes]"
}

# Resolve <repo>'s branch list, retrying the SSH form for HTTPS github URLs
# (for clients whose only github auth is SSH keys). stdout: the PROBE URL
# first (the form that answered; host-side git ops should use it), then one
# branch per line. Callers own the canonical/store URL, which stays HTTPS
# regardless of which form the probe needed. rc: 0 branches found,
# 3 reachable-but-empty, 2 unreachable.
_new_resolve_branches() {
  local repo="$1" branches rc=0
  if branches=$(_fetch_remote_branches "$repo"); then rc=0; else rc=$?; fi
  if [[ -z "$branches" && $rc -ne 0 ]]; then
    local ssh_repo
    ssh_repo=$(_github_https_to_ssh "$repo")
    if [[ "$ssh_repo" != "$repo" ]]; then
      if branches=$(_fetch_remote_branches "$ssh_repo"); then rc=0; else rc=$?; fi
      [[ $rc -eq 0 ]] && repo="$ssh_repo"
    fi
  fi
  [[ -z "$branches" && $rc -ne 0 ]] && return 2
  printf '%s\n' "$repo"
  [[ -z "$branches" ]] && return 3
  printf '%s\n' "$branches"
  return 0
}

cmd_new() {
  # Plumbing for the TUI wizard — resolve/inspect only, no side effects.
  # Comes before the devpod prerequisite check: neither needs devpod or a name.
  if [[ "${1:-}" == "--list-branches" ]]; then
    [[ -n "${2:-}" ]] || { _new_usage; return 1; }
    local canon out prc=0
    canon=$(_canonicalize_repo_url "$2")
    if out=$(_new_resolve_branches "$canon"); then prc=0; else prc=$?; fi
    [[ $prc -eq 2 ]] && return 2
    # Line 1 of the resolver is the probe URL, which may be the SSH fallback.
    # The TUI adopts line 1 as the workspace repo, so emit the canonical
    # HTTPS URL there instead.
    printf '%s\n' "$canon"
    tail -n +2 <<<"$out"
    return "$prc"
  fi
  if [[ "${1:-}" == "--check-devcontainer" ]]; then
    [[ -n "${2:-}" && -n "${3:-}" ]] || { _new_usage; return 1; }
    local prc=0
    _branch_has_devcontainer "$2" "$3" || prc=$?
    return "$prc"
  fi

  command -v devpod >/dev/null || { ui_error "devpod not installed; run dvw doctor"; return 1; }

  # Reject a value that's missing or looks like the next flag (e.g. `--repo
  # --name x`, a common typo when a value is accidentally omitted) rather
  # than silently swallowing the following flag as this one's value.
  # --ide defaults to ssh: every connect starts as ssh, Cursor is picked per
  # connect from the menu. `cursor` stays accepted for scripted callers.
  local repo="" branch="" name="" ide="ssh" init_empty=0 seed_devc=0 yes=0
  while (($#)); do
    case "$1" in
      --repo)   [[ -n "${2:-}" && "$2" != --* ]] || { ui_error "dvw new: --repo requires a value"; _new_usage; return 1; }
                repo="$2";   shift 2 ;;
      --branch) [[ -n "${2:-}" && "$2" != --* ]] || { ui_error "dvw new: --branch requires a value"; _new_usage; return 1; }
                branch="$2"; shift 2 ;;
      --name)   [[ -n "${2:-}" && "$2" != --* ]] || { ui_error "dvw new: --name requires a value"; _new_usage; return 1; }
                name="$2";   shift 2 ;;
      --ide)    [[ -n "${2:-}" && "$2" != --* ]] || { ui_error "dvw new: --ide requires a value"; _new_usage; return 1; }
                ide="$2";    shift 2 ;;
      --init-empty)         init_empty=1; shift ;;
      --seed-devcontainer)  seed_devc=1;  shift ;;
      --yes)                yes=1;        shift ;;
      *) ui_error "dvw new: unknown argument: $1"; _new_usage; return 1 ;;
    esac
  done
  [[ -z "$repo" ]] && { ui_error "dvw new: --repo is required"; _new_usage; return 1; }
  [[ -z "$name" ]] && { ui_error "dvw new: --name is required"; _new_usage; return 1; }
  case "$ide" in cursor|ssh) ;; *)
    ui_error "dvw new: --ide must be ssh or cursor (got: ${ide:-<empty>})"; _new_usage; return 1 ;;
  esac
  if [[ -z "$branch" ]]; then
    if (( init_empty )); then branch="main"; else
      ui_error "dvw new: --branch is required (or --init-empty for a fresh repo)"; _new_usage; return 1
    fi
  fi

  # Canonicalize: the workspace URL is always the HTTPS github form (SSH
  # origins cloned into containers cannot push; containers auth over HTTPS).
  local repo_in="$repo"
  repo=$(_canonicalize_repo_url "$repo")
  if [[ "$repo" != "$repo_in" ]]; then
    ui_info "using HTTPS form for github: $repo"
  fi

  # Resolve branches; handle empty/unreachable. probe_repo is the URL form
  # that actually answered on THIS host (may be the SSH fallback when the
  # client has no HTTPS credential helper); all host-side git operations use
  # it. The workspace itself keeps the canonical HTTPS $repo.
  local resolved rc=0 branches did_init=0 probe_repo
  if resolved=$(_new_resolve_branches "$repo"); then rc=0; else rc=$?; fi
  if [[ $rc -eq 2 ]]; then
    ui_error "couldn't list branches for $repo — check the URL, your network, or git auth"
    return 1
  fi
  probe_repo=$(head -n1 <<<"$resolved")
  branches=$(tail -n +2 <<<"$resolved")
  if [[ "$probe_repo" != "$repo" ]]; then
    ui_status_warn "this host answered github only over SSH; \`devpod up\` clones over HTTPS and may fail for private repos (fix: gh auth setup-git; see dvw doctor)"
  fi
  if [[ $rc -eq 3 ]]; then
    if (( ! init_empty )); then
      ui_error "repo is empty (no branches): $repo — rerun with --init-empty to create an initial commit (with the blueprint devcontainer.json) on '$branch'"
      return 1
    fi
    ui_action "initializing" "$repo (initial commit on $branch)"
    if ! _init_empty_repo "$probe_repo" "$branch"; then
      ui_error "failed to initialize empty repo: $repo — check your push access"
      return 1
    fi
    if [[ "${DVW_INIT_SEEDED_DEVCONTAINER:-0}" -eq 1 ]]; then
      ui_status_ok "initialized $repo with the blueprint devcontainer.json on '$branch'"
    else
      ui_status_warn "couldn't fetch the blueprint devcontainer.json — initialized $repo with a plain empty commit on '$branch' (the container will come up bare)"
    fi
    did_init=1
  else
    if ! grep -qxF -- "$branch" <<<"$branches"; then
      ui_error "branch '$branch' not found on $repo"
      ui_info "available: $(tr '\n' ' ' <<<"$branches")"
      return 1
    fi
  fi

  # Devcontainer presence (skipped when we just seeded the repo ourselves).
  if (( ! did_init )); then
    local devc_rc=0
    _branch_has_devcontainer "$probe_repo" "$branch" || devc_rc=$?
    if [[ $devc_rc -eq 1 ]]; then
      if (( seed_devc )); then
        ui_action "seeding" "blueprint devcontainer.json onto $branch"
        if _seed_devcontainer_on_branch "$probe_repo" "$branch"; then
          ui_status_ok "seeded .devcontainer/devcontainer.json on '$branch'"
        else
          ui_error "seeding failed (blueprint fetch or push) — continuing; the container will come up bare"
        fi
      else
        ui_status_warn "no devcontainer.json on '$branch' — the container will come up bare (pass --seed-devcontainer to seed the blueprint)"
      fi
    elif [[ $devc_rc -eq 2 ]]; then
      ui_status_warn "couldn't inspect '$branch' for a devcontainer.json — continuing"
    fi
  fi

  # Name: sanitize + cap + collision checks (verbatim from the old body,
  # minus the interactive prompt — the name now arrives via --name).
  name=$(_sanitize_ws_name "$name")
  [[ -z "$name" ]] && { ui_error "dvw new: --name sanitized to empty"; return 1; }
  if (( ${#name} > DEVPOD_NAME_MAX )); then
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

  # Confirm (unless --yes), then the existing devpod-up/cleanup/catalog tail verbatim.
  local devpod_ide="$ide"
  [[ "$ide" == "ssh" ]] && devpod_ide="none"
  printf '%srepo%s    %s\n%sbranch%s  %s\n%sname%s    %s\n%sIDE%s     %s\n' \
    "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)" "$repo" \
    "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)" "$branch" \
    "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)" "$name" \
    "$(_ansi "$DVW_SUBTLE")" "$(ui_reset)" "$ide"
  if (( ! yes )) && ! ui_confirm "Create workspace?"; then
    ui_info "aborted"
    return 1
  fi

  # 6. Run devpod up
  ui_action "creating" "$name (ide=$devpod_ide)"
  if devpod up "${repo}@${branch}" --id "$name" --ide "$devpod_ide"; then
    # devpod wrote its own SSH stanza (ForwardAgent yes) — reconcile it to the
    # dvw standard. Best-effort: a fresh workspace is still usable without it.
    _dvw_ensure_ssh_alias "$name" || true
  else
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
  ui_info "seed drops .devcontainer/ only — after first connect, run /scaffold-project inside the container"
}
