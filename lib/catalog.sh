#!/usr/bin/env bash
# Catalog read/write/mutation. Pure functions, no UI.
# All functions read $DVW_CATALOG (or default path) for catalog location.

DVW_CATALOG_DEFAULT="$HOME/Dropbox-remote/dvw/catalog.json"

catalog_path() {
  echo "${DVW_CATALOG:-$DVW_CATALOG_DEFAULT}"
}

catalog_init_if_missing() {
  local path
  path=$(catalog_path)
  local dir
  dir=$(dirname "$path")
  if [[ ! -d "$dir" ]]; then
    echo "catalog unreachable: $dir does not exist (rclone mount likely down)" >&2
    echo "try: systemctl --user status rclone-dropbox" >&2
    return 1
  fi
  if [[ -e "$path" ]]; then
    return 0
  fi
  cat > "$path" <<'JSON'
{
  "version": 1,
  "defaults": { "ide": "cursor", "provider": "vossisrv" },
  "workspaces": [],
  "repos": []
}
JSON
}

# Print catalog JSON to stdout, validating schema version.
# Caller is responsible for catalog_init_if_missing if they want auto-create.
catalog_read() {
  local path
  path=$(catalog_path)
  if [[ ! -f "$path" ]]; then
    echo "catalog not found: $path" >&2
    return 1
  fi
  if ! jq -e . "$path" >/dev/null 2>&1; then
    echo "catalog malformed (parse failed): $path" >&2
    echo "open it in an editor and fix; dvw will not overwrite" >&2
    return 1
  fi
  local version
  version=$(jq -r '.version // 0' "$path")
  if (( version > 1 )); then
    echo "catalog version $version is newer than this dvw supports — upgrade this machine" >&2
    return 1
  fi
  cat "$path"
}

# Read JSON from stdin, validate, atomically write to catalog path.
catalog_write() {
  local path tmp content
  path=$(catalog_path)
  tmp="$path.tmp"
  content=$(cat)
  if ! echo "$content" | jq -e . >/dev/null 2>&1; then
    echo "catalog_write: refusing to write malformed JSON" >&2
    return 1
  fi
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$path"
}

# Print workspace IDs, one per line, sorted by last_used_at descending.
catalog_workspace_ids() {
  catalog_read | jq -r '.workspaces | sort_by(.last_used_at) | reverse | .[].id'
}

# Print the workspace object for the given ID. Exit 1 if not found.
catalog_workspace_get() {
  local id="$1"
  local result
  result=$(catalog_read | jq -e --arg id "$id" '.workspaces[] | select(.id == $id)') || {
    echo "workspace not found in catalog: $id" >&2
    return 1
  }
  echo "$result"
}

# ISO-8601 UTC timestamp helper.
catalog_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Append a new workspace. Args: id repo branch ide provider hostname
catalog_workspace_add() {
  local id="$1" repo="$2" branch="$3" ide="$4" provider="$5" host="$6"
  local now content
  now=$(catalog_now)
  content=$(catalog_read) || return 1
  if echo "$content" | jq -e --arg id "$id" '.workspaces[] | select(.id == $id)' >/dev/null; then
    echo "workspace ID already exists: $id" >&2
    return 1
  fi
  echo "$content" | jq --arg id "$id" --arg repo "$repo" --arg branch "$branch" \
    --arg ide "$ide" --arg provider "$provider" --arg host "$host" --arg now "$now" \
    '.workspaces += [{
       id: $id, repo: $repo, branch: $branch, ide: $ide, provider: $provider,
       created_at: $now, last_used_at: $now, created_on: $host
     }]' | catalog_write
}

# Remove workspace by ID. Returns success even if ID not present.
catalog_workspace_remove() {
  local id="$1"
  catalog_read | jq --arg id "$id" '.workspaces |= map(select(.id != $id))' | catalog_write
}

# Bump last_used_at on a workspace. Returns success even if ID missing.
catalog_workspace_touch() {
  local id="$1" now
  now=$(catalog_now)
  catalog_read | jq --arg id "$id" --arg now "$now" \
    '.workspaces |= map(if .id == $id then .last_used_at = $now else . end)' \
    | catalog_write
}

# Insert or update a repo entry (keyed by URL).
catalog_repo_upsert() {
  local url="$1" branch="$2" now
  now=$(catalog_now)
  catalog_read | jq --arg url "$url" --arg branch "$branch" --arg now "$now" '
    if (.repos | map(.url) | index($url)) == null then
      .repos += [{ url: $url, last_branch: $branch, last_used_at: $now }]
    else
      .repos |= map(if .url == $url
                    then .last_branch = $branch | .last_used_at = $now
                    else . end)
    end' | catalog_write
}

# Print repo URLs in MRU order, one per line.
catalog_repo_list() {
  catalog_read | jq -r '.repos | sort_by(.last_used_at) | reverse | .[].url'
}

# Print last_branch for a URL, or empty if not in catalog.
catalog_repo_last_branch() {
  local url="$1"
  catalog_read | jq -r --arg url "$url" \
    '.repos[] | select(.url == $url) | .last_branch' 2>/dev/null
}

# Read a default value by key (e.g., "ide", "provider").
catalog_default() {
  local key="$1"
  catalog_read | jq -r --arg k "$key" '.defaults[$k] // ""'
}
