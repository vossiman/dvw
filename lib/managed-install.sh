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
  if [[ -e "$source/.git" ]]; then
    version=$(git -C "$source" rev-parse HEAD 2>/dev/null) || return 1
  elif [[ -f "$source/.aicoding-version" ]]; then
    version=$(tr -d '[:space:]' < "$source/.aicoding-version")
  else
    return 1
  fi
  [[ "$version" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$version"
}

_dvw_managed_validate_release() {
  local release="$1" version="$2" file lib
  [[ -x "$release/dvw" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$release/.aicoding-version" 2>/dev/null)" == "$version" ]] || return 1
  if find "$release" \
      \( -type l -o -type d \( -name .venv -o -name __pycache__ \
        -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache \
        -o -name node_modules \) -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
      -print -quit | grep -q .; then
    return 1
  fi
  for lib in catalog catalog-http-lib config ssh-sync wsl-bridge clipd connect \
    connect-resolver push pull push-watch commands wizard pin pin-rebuild ui \
    update-check update-super tui-launch version win-ssh-proxy; do
    [[ -f "$release/lib/$lib.sh" ]] || return 1
  done
  while IFS= read -r -d '' file; do
    bash -n "$file" || return 1
  done < <(find "$release" -type f \( -name '*.sh' -o -name dvw \) -print0)
}

_dvw_managed_stage_source() {
  local source="$1" version="$2" stage="$3" path
  local -a paths=()
  for path in dvw lib clipd tui cursor-shim.sh install-cursor-shim.sh tmux; do
    if [[ -e "$source/.git" ]]; then
      git -C "$source" cat-file -e "$version:$path" 2>/dev/null && paths+=("$path")
    elif [[ -e "$source/$path" || -L "$source/$path" ]]; then
      paths+=("$path")
    fi
  done
  (( ${#paths[@]} )) || return 1

  if [[ -e "$source/.git" ]]; then
    (
      set -o pipefail
      git -C "$source" archive --format=tar "$version" -- "${paths[@]}" |
        tar -xf - -C "$stage"
    )
  else
    (
      set -o pipefail
      tar -C "$source" \
        --exclude='.venv' --exclude='*/.venv' \
        --exclude='__pycache__' --exclude='*/__pycache__' \
        --exclude='.pytest_cache' --exclude='*/.pytest_cache' \
        --exclude='.mypy_cache' --exclude='*/.mypy_cache' \
        --exclude='.ruff_cache' --exclude='*/.ruff_cache' \
        --exclude='node_modules' --exclude='*/node_modules' \
        --exclude='*.pyc' --exclude='*.pyo' \
        -cf - -- "${paths[@]}" |
        tar -xf - -C "$stage"
    )
  fi
}

_dvw_managed_write_launcher() {
  local tmp="$1" data_dir="$2"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' &&
    printf 'data_dir=%q\n' "$data_dir" &&
    printf 'release=$(readlink -f "$data_dir/current/dvw")\n' &&
    printf '[[ -n "$release" && -x "$release/dvw" ]] || { echo "dvw: managed installation is unavailable" >&2; exit 1; }\n' &&
    printf 'exec "$release/dvw" "$@"\n'
  } > "$tmp"
}

_dvw_managed_chmod_launcher() {
  chmod 0755 "$1"
}

_dvw_managed_stage_launcher() {
  local data_dir="$1" bin_dir="$HOME/.local/bin" tmp
  mkdir -p "$bin_dir" || return 1
  tmp=$(mktemp "$bin_dir/.dvw.XXXXXX") || return 1
  if ! _dvw_managed_write_launcher "$tmp" "$data_dir" ||
      ! _dvw_managed_chmod_launcher "$tmp"; then
    rm -f "$tmp" || true
    return 1
  fi
  if ! printf '%s\n' "$tmp"; then
    rm -f "$tmp" || true
    return 1
  fi
}

_dvw_managed_prepare_marker_dir() { mkdir -p "$1"; }
_dvw_managed_write_marker() { printf '%s\n' "$2" > "$1"; }
_dvw_managed_write_version() { printf '%s\n' "$2" > "$1"; }
_dvw_managed_publish_release() { mv "$1" "$2"; }
_dvw_managed_open_lock() { exec 9>"$1"; }
_dvw_managed_acquire_lock() { flock 9; }

_dvw_managed_commit_launcher() {
  mv -f "$1" "$2"
}

_dvw_managed_commit_marker() {
  mv -f "$1" "$2"
}

_dvw_managed_switch_link() {
  local directory="$1" name="$2" target="$3" tmp
  mkdir -p "$directory" || return 1
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
  local destination="$1" backup="$2" existed="${3:-0}"
  if (( existed )); then
    [[ -n "$backup" ]] || return 1
    [[ -e "$backup" || -L "$backup" ]] || return 1
    mv -f "$backup" "$destination"
  else
    rm -f "$destination"
  fi
}

dvw_managed_install() (
  local source="${1:-}" version="${2:-}" source_version data_dir versions release
  local stage="" old_current old_previous marker marker_tmp="" path
  local launcher launcher_tmp="" launcher_backup="" marker_backup="" rc=0 rollback_rc=0
  local launcher_existed=0 marker_existed=0 launcher_touched=0 marker_touched=0
  local current_touched=0 previous_touched=0 initial_enrollment=0 recovery=""
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
  if ! mkdir -p "$versions" "$data_dir/current" "$data_dir/previous"; then
    echo "dvw managed install: runtime directory preparation failed" >&2
    return 1
  fi
  command -v flock >/dev/null 2>&1 || {
    echo "dvw managed install: flock is required" >&2
    return 1
  }
  if ! _dvw_managed_open_lock "$data_dir/.dvw-install.lock"; then
    echo "dvw managed install: could not open install lock" >&2
    return 1
  fi
  if ! _dvw_managed_acquire_lock; then
    echo "dvw managed install: could not acquire install lock" >&2
    return 1
  fi

  if [[ -e "$release" ]]; then
    _dvw_managed_validate_release "$release" "$version" || {
      echo "dvw managed install: existing release is invalid" >&2
      return 1
    }
  else
    stage=$(mktemp -d "$versions/.${version}.stage.XXXXXX") || return 1
    _dvw_managed_stage_source "$source" "$version" "$stage" || {
      rm -rf "$stage"
      echo "dvw managed install: source staging failed" >&2
      return 1
    }
    if ! _dvw_managed_write_version "$stage/.aicoding-version" "$version"; then
      rm -rf "$stage"
      echo "dvw managed install: staged version write failed" >&2
      return 1
    fi
    if ! _dvw_managed_validate_release "$stage" "$version"; then
      rm -rf "$stage"
      echo "dvw managed install: staged client validation failed" >&2
      return 1
    fi
    if ! _dvw_managed_publish_release "$stage" "$release"; then
      rm -rf "$stage"
      echo "dvw managed install: release publication failed" >&2
      return 1
    fi
    stage=""
    if ! _dvw_managed_validate_release "$release" "$version"; then
      rm -rf "$release"
      echo "dvw managed install: published release validation failed" >&2
      return 1
    fi
  fi

  old_current=""
  old_previous=""
  if [[ -L "$data_dir/current/dvw" ]]; then
    old_current=$(readlink -f "$data_dir/current/dvw" 2>/dev/null || true)
  fi
  if [[ -L "$data_dir/previous/dvw" ]]; then
    old_previous=$(readlink -f "$data_dir/previous/dvw" 2>/dev/null || true)
  fi
  launcher="$HOME/.local/bin/dvw"
  launcher_tmp=$(_dvw_managed_stage_launcher "$data_dir") || {
    echo "dvw managed install: launcher staging failed" >&2
    return 1
  }
  marker="${DVW_STATE_DIR:-$HOME/.local/state/dvw}/version"
  if ! _dvw_managed_prepare_marker_dir "$(dirname "$marker")"; then
    rm -f "$launcher_tmp" || true
    echo "dvw managed install: marker staging failed" >&2
    return 1
  fi
  marker_tmp=$(mktemp "${marker}.XXXXXX") || {
    rm -f "$launcher_tmp" || true
    echo "dvw managed install: marker staging failed" >&2
    return 1
  }
  if ! _dvw_managed_write_marker "$marker_tmp" "$version" ||
      [[ "$(tr -d '[:space:]' < "$marker_tmp" 2>/dev/null)" != "$version" ]]; then
    rm -f "$launcher_tmp" "$marker_tmp" || true
    echo "dvw managed install: marker staging failed" >&2
    return 1
  fi

  if [[ -e "$launcher" || -L "$launcher" ]]; then
    launcher_backup="${launcher}.backup.$$"
    if cp -a "$launcher" "$launcher_backup"; then
      launcher_existed=1
    else
      rc=1
    fi
  fi
  if (( rc == 0 )) && [[ -e "$marker" || -L "$marker" ]]; then
    marker_backup="${marker}.backup.$$"
    if cp -a "$marker" "$marker_backup"; then
      marker_existed=1
    else
      rc=1
    fi
  fi
  if (( rc != 0 )); then
    for path in "$launcher_tmp" "$marker_tmp" "$launcher_backup" "$marker_backup"; do
      [[ -z "$path" ]] || rm -f "$path" || true
    done
    echo "dvw managed install: backup preparation failed; active release unchanged" >&2
    return 1
  fi

  _dvw_managed_rollback_activation() {
    rollback_rc=0
    if (( launcher_touched )); then
      if _dvw_managed_restore_file "$launcher" "$launcher_backup" "$launcher_existed"; then
        launcher_backup=""
      else
        rollback_rc=1
        [[ -z "$launcher_backup" ]] || recovery+=" $launcher_backup"
      fi
    fi
    if (( marker_touched )); then
      if _dvw_managed_restore_file "$marker" "$marker_backup" "$marker_existed"; then
        marker_backup=""
      else
        rollback_rc=1
        [[ -z "$marker_backup" ]] || recovery+=" $marker_backup"
      fi
    fi
    if (( current_touched )); then
      _dvw_managed_restore_link "$data_dir/current" dvw "$old_current" || rollback_rc=1
    fi
    if (( previous_touched )); then
      _dvw_managed_restore_link "$data_dir/previous" dvw "$old_previous" || rollback_rc=1
    fi
    for path in "$launcher_tmp" "$marker_tmp"; do
      [[ -z "$path" ]] || rm -f "$path" || rollback_rc=1
    done
    (( launcher_touched )) || { rm -f "$launcher_backup" || true; launcher_backup=""; }
    (( marker_touched )) || { rm -f "$marker_backup" || true; marker_backup=""; }
    return "$rollback_rc"
  }

  _dvw_managed_report_rollback() {
    if (( rollback_rc == 0 )); then
      if [[ -n "$old_current" ]]; then
        echo "dvw managed install: activation failed; previous release restored" >&2
      else
        echo "dvw managed install: activation failed; prior state restored" >&2
      fi
    else
      echo "dvw managed install: activation failed; rollback incomplete" >&2
      [[ -z "$recovery" ]] || echo "dvw managed install: recovery backup retained:${recovery}" >&2
      [[ -z "$old_current" ]] || echo "dvw managed install: old release retained: $old_current" >&2
    fi
  }

  _dvw_managed_handle_signal() {
    local signal="$1" code="$2"
    trap - TERM INT HUP
    _dvw_managed_rollback_activation || true
    echo "dvw managed install: interrupted by $signal" >&2
    _dvw_managed_report_rollback
    exit "$code"
  }

  [[ -z "$old_current" ]] && initial_enrollment=1
  trap '_dvw_managed_handle_signal TERM 143' TERM
  trap '_dvw_managed_handle_signal INT 130' INT
  trap '_dvw_managed_handle_signal HUP 129' HUP

  if (( initial_enrollment )); then
    # Keep any legacy launcher usable until marker and pointer are ready. The
    # launcher rename is the final behavior-changing step during enrollment.
    marker_touched=1
    _dvw_managed_commit_marker "$marker_tmp" "$marker" || rc=1
    if (( rc == 0 )); then
      if _dvw_managed_switch_link "$data_dir/current" dvw "$release"; then
        current_touched=1
      else
        rc=1
      fi
    fi
    if (( rc == 0 )); then
      launcher_touched=1
      _dvw_managed_commit_launcher "$launcher_tmp" "$launcher" || rc=1
    fi
  else
    if [[ "$old_current" != "$release" ]]; then
      if _dvw_managed_switch_link "$data_dir/previous" dvw "$old_current"; then
        previous_touched=1
      else
        rc=1
      fi
    fi
    if (( rc == 0 )); then
      launcher_touched=1
      _dvw_managed_commit_launcher "$launcher_tmp" "$launcher" || rc=1
    fi
    if (( rc == 0 )); then
      marker_touched=1
      _dvw_managed_commit_marker "$marker_tmp" "$marker" || rc=1
    fi
    # Existing managed launchers continue following the old pointer until this
    # final fallible activation step succeeds.
    if (( rc == 0 )); then
      if _dvw_managed_switch_link "$data_dir/current" dvw "$release"; then
        current_touched=1
      else
        rc=1
      fi
    fi
  fi

  trap - TERM INT HUP
  if (( rc != 0 )); then
    _dvw_managed_rollback_activation || true
    _dvw_managed_report_rollback
    return 1
  fi

  for path in "$launcher_backup" "$marker_backup"; do
    [[ -z "$path" ]] || rm -f "$path" || true
  done
  printf 'dvw managed install: activated %s\n' "$version" || true
  return 0
)
