#!/usr/bin/env bash
# dvw client configuration. An optional per-machine config file lets you pin the
# catalog host / provider instead of relying on the built-in defaults (which
# target the reference deployment). Without a file, dvw behaves exactly as
# before — every value still has a default.
#
#   File:  ${DVW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/dvw/config}
#   Form:  plain `KEY=value` lines; `#` comments and blank lines ignored
#   Keys:  DVW_CATALOG_HOST  DVW_CATALOG_SOCK  DVW_CATALOG_TOKEN  DVW_PROVIDER
#
# Precedence is env > config file > built-in default: the file only fills a key
# not already set in the environment, and the libs keep their `${VAR:-…}`
# fallbacks. The file is PARSED, not sourced, so a stray line can't run code.

DVW_CONFIG="${DVW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/dvw/config}"

# Keys dvw honors from the file; anything else is ignored without error.
DVW_CONFIG_KEYS="DVW_CATALOG_HOST DVW_CATALOG_SOCK DVW_CATALOG_TOKEN DVW_PROVIDER"

# dvw_load_config [FILE]
# Apply recognized KEY=value lines as environment, but only where the variable
# is currently unset (env wins). Missing/unreadable file is a silent no-op.
dvw_load_config() {
  local file="${1:-$DVW_CONFIG}" line key val
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                 # drop trailing comment
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"         # keys carry no spaces
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    [[ "$val" == \"*\" || "$val" == \'*\' ]] && val="${val:1:${#val}-2}"  # unquote
    [[ " $DVW_CONFIG_KEYS " == *" $key "* ]] || continue   # known keys only
    [[ -n "${!key:-}" ]] && continue   # already set in the environment → keep it
    export "$key=$val"
  done < "$file"
}

# dvw_config_set KEY VALUE [FILE]
# Persist KEY=VALUE into the config file, replacing any existing line for KEY.
# Creates the file (and its directory) if needed; chmod 0600 since it may hold a
# token. Atomic via temp-file + mv.
dvw_config_set() {
  local key="$1" val="$2" file="${3:-$DVW_CONFIG}" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.config.XXXXXX")"
  [[ -f "$file" ]] && grep -vE "^[[:space:]]*${key}[[:space:]]*=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
  chmod 0600 "$file"
}
