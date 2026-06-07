# dvw update notifier — is the dvw checkout behind origin/main? Throttled,
# fail-open, never blocks. The startup nudge (in `dvw`) and `dvw doctor` read
# the cached result; a detached `git fetch` refreshes it past the TTL.
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
_dvw_update_do_refresh() {
  local cache behind now tmp
  cache=$(dvw_update_cache_path)
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  git -C "$DVW_ROOT" fetch -q origin main 2>/dev/null || return 0
  behind=$(git -C "$DVW_ROOT" rev-list --count HEAD..origin/main 2>/dev/null)
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
  git -C "$DVW_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
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

# Print the one-line startup nudge if behind. $1 = the subcommand being
# dispatched; the nudge is suppressed for `update` (no point nagging mid-update)
# and silent when up to date (0) or unknown (empty). Reads cached state only.
dvw_update_maybe_nudge() {
  [ "${1:-}" = "update" ] && return 0
  local behind; behind=$(dvw_update_behind_count)
  case "$behind" in ''|0) return 0 ;; esac
  printf '⬆ dvw behind main — run: dvw update\n'
}
