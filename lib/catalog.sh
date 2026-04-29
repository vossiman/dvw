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
