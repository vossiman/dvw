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

cmd_new() {
  command -v gum >/dev/null || { echo "gum not installed; run dvw doctor" >&2; return 1; }
  command -v devpod >/dev/null || { echo "devpod not installed; run dvw doctor" >&2; return 1; }

  # 1. Repo
  local repos repo
  repos=$(catalog_repo_list)
  if [[ -z "$repos" ]]; then
    repo=$(gum input --placeholder "git@github.com:owner/repo.git" --header "repo URL")
  else
    repo=$(printf "+ enter new...\n%s\n" "$repos" \
      | gum filter --placeholder "pick a repo (or '+ enter new...')")
    if [[ "$repo" == "+ enter new..." || -z "$repo" ]]; then
      repo=$(gum input --placeholder "git@github.com:owner/repo.git" --header "repo URL")
    fi
  fi
  [[ -z "$repo" ]] && { echo "aborted: no repo" >&2; return 1; }

  # 2. Branch
  local default_branch branch
  default_branch=$(catalog_repo_last_branch "$repo")
  default_branch="${default_branch:-main}"
  branch=$(gum input --value "$default_branch" --header "branch")
  [[ -z "$branch" ]] && { echo "aborted: no branch" >&2; return 1; }

  # 3. Workspace name
  local default_name name
  default_name=$(_sanitize_ws_name "$(_repo_leaf "$repo")-$branch")
  name=$(gum input --value "$default_name" --header "workspace name")
  name=$(_sanitize_ws_name "$name")
  [[ -z "$name" ]] && { echo "aborted: no name" >&2; return 1; }
  if catalog_workspace_get "$name" >/dev/null 2>&1; then
    echo "workspace ID already exists in catalog: $name" >&2
    return 1
  fi

  # 4. IDE
  local default_ide ide
  default_ide=$(catalog_default ide)
  default_ide="${default_ide:-cursor}"
  ide=$(gum choose --selected "$default_ide" cursor ssh)
  [[ -z "$ide" ]] && { echo "aborted: no ide" >&2; return 1; }

  # 5. Confirm
  local devpod_ide="$ide"
  [[ "$ide" == "ssh" ]] && devpod_ide="none"
  echo
  echo "Will run: devpod up '${repo}@${branch}' --id '$name' --ide $devpod_ide"
  gum confirm "Proceed?" || { echo "aborted"; return 1; }

  # 6. Run devpod up
  if ! devpod up "${repo}@${branch}" --id "$name" --ide "$devpod_ide"; then
    echo "devpod up failed; catalog not modified" >&2
    return 1
  fi

  # 7. Update catalog
  local provider host
  provider=$(catalog_default provider)
  provider="${provider:-vossisrv}"
  host=$(hostname -s)
  catalog_workspace_add "$name" "$repo" "$branch" "$ide" "$provider" "$host"
  catalog_repo_upsert "$repo" "$branch"
  echo "added to catalog: $name"
}
