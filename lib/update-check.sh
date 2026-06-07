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
