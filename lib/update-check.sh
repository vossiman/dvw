# dvw update notifier — is the tracked repo behind origin/main? That is the dvw
# checkout when standalone, and the SUPERPROJECT that pins it when dvw is a
# submodule (see dvw_update_target_repo). Throttled, fail-open, never blocks.
# The startup nudge (in `dvw`) and `dvw doctor` read the cached result; a
# detached `git fetch` refreshes it past the TTL.
#
# Cache file: two lines — <last-fetch-epoch>\n<behind-count>\n — in the same
# state dir as the version marker. dvw owns it; nothing else writes here.

# Throttle window (seconds). Matches aicoding's AICODING_UPDATE_TTL default.
DVW_UPDATE_TTL="${DVW_UPDATE_TTL:-21600}"   # 6h

dvw_update_cache_path() {
  printf '%s/update-check' "${DVW_STATE_DIR:-$HOME/.local/state/dvw}"
}

# Echo the cached behind-count. Empty = unknown (no/garbled cache). No network.
# Callers treat empty as "not checked yet" and 0 as "up to date". Always exit 0.
dvw_update_behind_count() {
  local cache count
  cache=$(dvw_update_cache_path)
  [ -f "$cache" ] || return 0
  count=$(sed -n '2p' "$cache" 2>/dev/null)
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "$count" ;;
  esac
  return 0
}

# Return 0 (stale → should refresh) if the cache is missing, unparsable, or
# older than DVW_UPDATE_TTL. Return 1 (fresh) otherwise.
_dvw_update_cache_stale() {
  local cache epoch now
  cache=$(dvw_update_cache_path)
  [ -f "$cache" ] || return 0
  epoch=$(sed -n '1p' "$cache" 2>/dev/null)
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $(( now - epoch )) -ge "$DVW_UPDATE_TTL" ]
}

# Synchronous refresh: fetch origin/main, record <epoch>\n<behind>. Fail-open —
# any failure (offline, bad remote) returns 0 and leaves the cache untouched, so
# the next run simply retries. Writes atomically via a temp file + mv.
#
# --no-write-fetch-head is load-bearing, not an optimisation: this fetch can run
# detached in the background (see dvw_update_refresh_if_stale) at the same time
# `dvw update` runs `git pull --ff-only origin main` in the foreground. Both
# would otherwise append `main` to the same FETCH_HEAD non-atomically, leaving a
# duplicate entry that makes the pull's merge abort with "Cannot fast-forward to
# multiple branches." We only need origin/main updated for the rev-list below —
# which --no-write-fetch-head still does — so skipping the FETCH_HEAD write
# removes the shared file the two fetches were racing on.
#
# --no-recurse-submodules is load-bearing for the same reason. The repo may set
# `submodule.recurse=true` (devMachine does), which makes every fetch recurse
# into the submodules — so the background check and the foreground pull in
# `dvw update` each update the submodules' origin/main too, and whichever is
# second fails with "cannot lock ref 'refs/remotes/origin/main': is at X but
# expected Y" (seen 2026-08-23 on devpod/memory-lanes). The rev-list below only
# needs the superproject's origin/main; submodule refs are never read here.
_dvw_update_do_refresh() {
  local cache behind now tmp repo
  cache=$(dvw_update_cache_path)
  repo=$(dvw_update_target_repo)
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  git -C "$repo" fetch -q --no-write-fetch-head --no-recurse-submodules origin main 2>/dev/null || return 0
  behind=$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null)
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  now=$(date +%s)
  tmp="${cache}.tmp.$$"
  printf '%s\n%s\n' "$now" "$behind" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
  return 0
}

# Refresh the cache iff stale. Fail-open and non-blocking: the fetch runs
# detached in the background (the foreground returns immediately and prints the
# CURRENT cached state). Set DVW_UPDATE_SYNC=1 to run it inline (tests).
dvw_update_refresh_if_stale() {
  _dvw_update_cache_stale || return 0
  git -C "$(dvw_update_target_repo)" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if [ -n "${DVW_UPDATE_SYNC:-}" ]; then
    _dvw_update_do_refresh
    return 0
  fi
  local lock; lock="$(dvw_update_cache_path).lock"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 0
  mkdir "$lock" 2>/dev/null || return 0     # another refresh already in flight
  ( _dvw_update_do_refresh; rmdir "$lock" 2>/dev/null || true ) >/dev/null 2>&1 &
  return 0
}

# Echo the working tree of the superproject that pins $DVW_ROOT as a submodule
# (e.g. devMachine), or nothing when this is a standalone checkout. Always 0.
dvw_superproject_root() {
  git -C "${DVW_ROOT:?}" rev-parse --show-superproject-working-tree 2>/dev/null || true
}

# True when $DVW_ROOT is a git submodule of another working tree.
dvw_is_submodule_checkout() {
  [[ -n "$(dvw_superproject_root)" ]]
}

# Which repo's staleness is worth reporting? Under a superproject it is the
# PARENT's: dvw sits at whatever commit the parent pins, so dvw's own main is
# routinely ahead of it and would nag forever. The parent's distance from its
# main is exactly what `dvw update` resolves.
dvw_update_target_repo() {
  local super; super=$(dvw_superproject_root)
  printf '%s' "${super:-${DVW_ROOT:?}}"
}

# Display name for that repo: the superproject's directory name, else "dvw".
dvw_update_target_name() {
  local super; super=$(dvw_superproject_root)
  if [[ -n "$super" ]]; then printf '%s' "$(basename "$super")"; else printf 'dvw'; fi
}

# Print the one-line startup nudge if behind. $1 = the subcommand being
# dispatched; the nudge is suppressed for `update` (no point nagging mid-update)
# and silent when up to date (0) or unknown (empty). Reads cached state only.
dvw_update_maybe_nudge() {
  [ "${1:-}" = "update" ] && return 0
  local behind; behind=$(dvw_update_behind_count)
  case "$behind" in ''|0) return 0 ;; esac
  printf '⬆ %s behind main — run: dvw update\n' "$(dvw_update_target_name)"
}
