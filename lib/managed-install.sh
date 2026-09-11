#!/usr/bin/env bash
# Staged dvw client installation for the common aicoding updater.

dvw_linux_asset_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

dvw_devpod_download_url() {
  local arch
  arch=$(dvw_linux_asset_arch) || return 1
  printf 'https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-%s\n' "$arch"
}

_dvw_managed_source_version() {
  local source="$1" version
  if [[ -f "$source/.aicoding-version" ]]; then
    version=$(tr -d '[:space:]' < "$source/.aicoding-version")
  else
    version=$(git -C "$source" rev-parse HEAD 2>/dev/null) || return 1
  fi
  [[ "$version" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$version"
}

_dvw_managed_validate_release() {
  local release="$1" version="$2" file lib
  [[ -x "$release/dvw" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$release/.aicoding-version" 2>/dev/null)" == "$version" ]] || return 1
  for lib in catalog catalog-http-lib config ssh-sync wsl-bridge clipd connect \
    connect-resolver push pull push-watch commands wizard pin pin-rebuild ui \
    update-check update-super tui-launch version win-ssh-proxy; do
    [[ -f "$release/lib/$lib.sh" ]] || return 1
  done
  while IFS= read -r -d '' file; do
    bash -n "$file" || return 1
  done < <(find "$release" -type f \( -name '*.sh' -o -name dvw \) -print0)
}

_dvw_managed_stage_launcher() {
  local data_dir="$1" bin_dir="$HOME/.local/bin" tmp
  mkdir -p "$bin_dir"
  tmp=$(mktemp "$bin_dir/.dvw.XXXXXX") || return 1
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'data_dir=%q\n' "$data_dir"
    printf 'release=$(readlink -f "$data_dir/current/dvw")\n'
    printf '[[ -n "$release" && -x "$release/dvw" ]] || { echo "dvw: managed installation is unavailable" >&2; exit 1; }\n'
    printf 'exec "$release/dvw" "$@"\n'
  } > "$tmp"
  chmod 0755 "$tmp"
  printf '%s\n' "$tmp"
}

_dvw_managed_commit_launcher() {
  mv -f "$1" "$2"
}

_dvw_managed_commit_marker() {
  mv -f "$1" "$2"
}

_dvw_managed_switch_link() {
  local directory="$1" name="$2" target="$3" tmp
  mkdir -p "$directory"
  tmp="$directory/.${name}.new.$$"
  ln -s "$target" "$tmp" || return 1
  if ! mv -Tf "$tmp" "$directory/$name"; then
    rm -f "$tmp"
    return 1
  fi
}

_dvw_managed_restore_link() {
  local directory="$1" name="$2" target="$3"
  if [[ -n "$target" ]]; then
    _dvw_managed_switch_link "$directory" "$name" "$target"
  else
    rm -f "$directory/$name"
  fi
}

_dvw_managed_restore_file() {
  local destination="$1" backup="$2"
  if [[ -n "$backup" ]]; then
    mv -f "$backup" "$destination"
  else
    rm -f "$destination"
  fi
}

dvw_managed_install() (
  local source="${1:-}" version="${2:-}" source_version data_dir versions release
  local stage="" old_current old_previous marker marker_tmp="" lock_fd path
  local launcher launcher_tmp="" launcher_backup="" marker_backup="" rc=0
  [[ "$version" =~ ^[0-9a-f]{40}$ ]] || {
    echo "dvw managed install: full SHA required" >&2
    return 1
  }
  [[ -d "$source" ]] || {
    echo "dvw managed install: source path missing" >&2
    return 1
  }
  source_version=$(_dvw_managed_source_version "$source") || {
    echo "dvw managed install: source version unavailable" >&2
    return 1
  }
  [[ "$source_version" == "$version" ]] || {
    echo "dvw managed install: source version mismatch" >&2
    return 1
  }

  data_dir="${AICODING_DATA_DIR:-$HOME/.local/share/aicoding}"
  versions="$data_dir/versions/dvw"
  release="$versions/$version"
  mkdir -p "$versions" "$data_dir/current" "$data_dir/previous"
  command -v flock >/dev/null 2>&1 || {
    echo "dvw managed install: flock is required" >&2
    return 1
  }
  exec {lock_fd}>"$data_dir/.dvw-install.lock"
  flock "$lock_fd"

  if [[ -e "$release" ]]; then
    _dvw_managed_validate_release "$release" "$version" || {
      echo "dvw managed install: existing release is invalid" >&2
      return 1
    }
  else
    stage=$(mktemp -d "$versions/.${version}.stage.XXXXXX") || return 1
    for path in dvw lib clipd tui cursor-shim.sh install-cursor-shim.sh tmux; do
      [[ -e "$source/$path" ]] || continue
      cp -a "$source/$path" "$stage/" || { rm -rf "$stage"; return 1; }
    done
    printf '%s\n' "$version" > "$stage/.aicoding-version"
    if ! _dvw_managed_validate_release "$stage" "$version"; then
      rm -rf "$stage"
      echo "dvw managed install: staged client validation failed" >&2
      return 1
    fi
    mv "$stage" "$release"
    stage=""
  fi

  old_current=$(readlink -f "$data_dir/current/dvw" 2>/dev/null || true)
  old_previous=$(readlink -f "$data_dir/previous/dvw" 2>/dev/null || true)
  launcher="$HOME/.local/bin/dvw"
  launcher_tmp=$(_dvw_managed_stage_launcher "$data_dir") || return 1
  marker="${DVW_STATE_DIR:-$HOME/.local/state/dvw}/version"
  mkdir -p "$(dirname "$marker")"
  marker_tmp=$(mktemp "${marker}.XXXXXX") || { rm -f "$launcher_tmp"; return 1; }
  printf '%s\n' "$version" > "$marker_tmp"

  if [[ -e "$launcher" || -L "$launcher" ]]; then
    launcher_backup="${launcher}.backup.$$"
    cp -a "$launcher" "$launcher_backup" || rc=1
  fi
  if (( rc == 0 )) && [[ -e "$marker" || -L "$marker" ]]; then
    marker_backup="${marker}.backup.$$"
    cp -a "$marker" "$marker_backup" || rc=1
  fi
  if [[ -n "$old_current" && "$old_current" != "$release" ]]; then
    (( rc == 0 )) && _dvw_managed_switch_link "$data_dir/previous" dvw "$old_current" || rc=1
  fi
  (( rc == 0 )) && _dvw_managed_switch_link "$data_dir/current" dvw "$release" || rc=1
  (( rc == 0 )) && _dvw_managed_commit_launcher "$launcher_tmp" "$launcher" || rc=1
  (( rc == 0 )) && _dvw_managed_commit_marker "$marker_tmp" "$marker" || rc=1

  if (( rc != 0 )); then
    _dvw_managed_restore_link "$data_dir/current" dvw "$old_current" || true
    _dvw_managed_restore_link "$data_dir/previous" dvw "$old_previous" || true
    _dvw_managed_restore_file "$launcher" "$launcher_backup" || true
    _dvw_managed_restore_file "$marker" "$marker_backup" || true
    for path in "$launcher_tmp" "$marker_tmp" "$launcher_backup" "$marker_backup"; do
      [[ -z "$path" ]] || rm -f "$path"
    done
    echo "dvw managed install: activation failed; previous release restored" >&2
    return 1
  fi

  for path in "$launcher_backup" "$marker_backup"; do
    [[ -z "$path" ]] || rm -f "$path"
  done
  printf 'dvw managed install: activated %s\n' "$version"
)
