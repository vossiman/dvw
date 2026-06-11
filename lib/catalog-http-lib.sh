#!/usr/bin/env bash
# Transport for dvw <-> dvw-catalog. No new ports: the service listens on a
# unix socket on vossisrv; we reach it with `curl --unix-socket` either
# locally (when dvw runs on the box) or over SSH (the normal laptop case).
#
# Config (env, with defaults matching the systemd unit):
#   DVW_CATALOG_HOST   ssh host alias for the provider   (default: vossisrv)
#   DVW_CATALOG_SOCK   unix socket path on the box        (default: /run/dvw-catalog/catalog.sock)
#   DVW_CATALOG_TOKEN  optional bearer token              (default: unset)
#
# Speed: rely on the laptop's ssh ControlMaster/ControlPersist (dvw already
# configures this via the blueprint's `Host *.devpod`) so the many small
# catalog calls reuse one multiplexed connection.

DVW_CATALOG_HOST="${DVW_CATALOG_HOST:-vossisrv}"
DVW_CATALOG_SOCK="${DVW_CATALOG_SOCK:-/run/dvw-catalog/catalog.sock}"

# Last HTTP status code from _catalog_req (string, e.g. "200").
DVW_CAT_STATUS=""

# _catalog_req METHOD PATH [JSON_BODY]
# Prints the response body on stdout, sets DVW_CAT_STATUS, returns:
#   0   transport ok AND status 2xx
#   1   transport ok but status >= 400
#   2   transport failure (ssh/curl could not reach the socket)
_catalog_req() {
  local method="$1" path="$2" body="${3:-}"
  local url="http://localhost${path}"
  local raw rc

  local -a curl_args=(-sS -X "$method" --unix-socket "$DVW_CATALOG_SOCK"
                      -w $'\n%{http_code}')
  [[ -n "${DVW_CATALOG_TOKEN:-}" ]] &&
    curl_args+=(-H "authorization: Bearer ${DVW_CATALOG_TOKEN}")
  if [[ -n "$body" ]]; then
    curl_args+=(-H 'content-type: application/json' --data-binary @-)
  fi
  curl_args+=("$url")

  if [[ -S "$DVW_CATALOG_SOCK" ]]; then
    # Running on the box itself — skip SSH.
    if [[ -n "$body" ]]; then
      raw=$(printf '%s' "$body" | curl "${curl_args[@]}" 2>/dev/null); rc=$?
    else
      raw=$(curl "${curl_args[@]}" 2>/dev/null); rc=$?
    fi
  else
    # Over ssh the remote login shell RE-PARSES the command, so ssh's naive
    # space-join of argv is unsafe: any arg containing whitespace — the -w
    # status format's newline, or an `authorization: Bearer <token>` header —
    # would be word-split into separate tokens and mangle the request (this is
    # what made `dvw doctor` report the service unreachable). Build an
    # explicitly quoted command string with printf %q so the remote shell
    # reconstructs the exact argv we intended.
    local rcmd='curl' _a
    for _a in "${curl_args[@]}"; do printf -v rcmd '%s %q' "$rcmd" "$_a"; done
    if [[ -n "$body" ]]; then
      raw=$(printf '%s' "$body" \
        | ssh -o BatchMode=yes -o ConnectTimeout=5 "$DVW_CATALOG_HOST" "$rcmd" 2>/dev/null)
      rc=$?
    else
      raw=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$DVW_CATALOG_HOST" "$rcmd" 2>/dev/null)
      rc=$?
    fi
  fi

  if (( rc != 0 )) || [[ -z "$raw" ]]; then
    DVW_CAT_STATUS=""
    return 2
  fi

  DVW_CAT_STATUS="${raw##*$'\n'}"   # last line
  local out="${raw%$'\n'*}"          # everything before it
  printf '%s' "$out"

  [[ "$DVW_CAT_STATUS" =~ ^2 ]] && return 0
  return 1
}

# Convenience: GET that returns body only on 2xx, else empty + nonzero.
_catalog_get() { _catalog_req GET "$1"; }

# True if the service is reachable and healthy.
_catalog_reachable() {
  _catalog_req GET /v1/health >/dev/null 2>&1
}
