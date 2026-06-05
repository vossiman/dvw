# dvw's own installed-version marker. dvw owns this file; external tools (e.g.
# the aicoding update notifier) only READ it — they never write here.

# Path to the marker. Overridable via DVW_STATE_DIR for tests.
dvw_version_marker_path() {
  printf '%s/version' "${DVW_STATE_DIR:-$HOME/.local/state/dvw}"
}

# Record <repo_dir>'s HEAD SHA into the marker. No-op (warn) if not a git repo.
dvw_write_version_marker() {
  local repo=$1 sha marker dir
  sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || { echo "WARN: $repo is not a git checkout — not recording dvw version" >&2; return 0; }
  marker=$(dvw_version_marker_path); dir=$(dirname "$marker")
  mkdir -p "$dir"
  printf '%s\n' "$sha" > "$marker"
}

# Echo the installed SHA, or empty if no marker.
dvw_installed_version() {
  local marker; marker=$(dvw_version_marker_path)
  [ -f "$marker" ] && tr -d '[:space:]' < "$marker" || true
}
