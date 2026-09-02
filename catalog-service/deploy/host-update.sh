#!/usr/bin/env bash
# Update dvw-catalog ON vossisrv: git pull + uv sync + restart. One command.
# Run as `vossi` on vossisrv (restart is passwordless via the sudoers drop-in
# that host-install.sh laid down).
#
#   /opt/dvw/catalog-service/deploy/host-update.sh
set -euo pipefail
# On a 401 git would otherwise stop at a "Username for" prompt, and the
# retry below never runs. Fail fast instead; the pull is anonymous anyway.
export GIT_TERMINAL_PROMPT=0

CHECKOUT="${CHECKOUT:-/opt/dvw}"
SVC_DIR="$CHECKOUT/catalog-service"
SOCK="/run/dvw-catalog/catalog.sock"

# GitHub rejects roughly half of first unauthenticated fetch attempts with a
# 401 (2026-09-02; the retry always succeeded). Three tries, short pause.
git_retry() {
  local attempt
  for attempt in 1 2 3; do
    "$@" && return 0
    [ "$attempt" -lt 3 ] || return 1
    echo "    $* failed (attempt $attempt/3); retrying" >&2
    sleep "${DVW_GIT_RETRY_DELAY:-2}"
  done
}

# Authenticated git. The host user keeps no GitHub login, but the estate's
# shared secrets store is bind-mounted here, and gh-token-helper reads the
# token from it per request without ever putting it on a command line. With
# no readable store the helper answers nothing and git falls back to an
# anonymous fetch, which GitHub refuses often enough (401 on the
# upload-pack POST, 2026-09-02) that the retry above exists.
GH_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-token-helper"
git_auth() {
  git -c credential.helper= -c "credential.helper=$GH_HELPER" "$@"
}

echo "==> git pull"
git -C "$CHECKOUT" config protocol.version 1
git_retry git_auth -C "$CHECKOUT" pull --ff-only

echo "==> uv sync --frozen"
export PATH="$HOME/.local/bin:$PATH"
( cd "$SVC_DIR" && uv sync --frozen --no-dev )

# Reinstall units if they changed in this pull. Render User=/Group= for the
# running user — same as host-install.sh — so an update never reverts the
# template back to the committed `vossi` default (and we compare the RENDERED
# unit, not the raw file, so a non-vossi install doesn't reinstall every time).
RUN_GROUP="$(id -gn)"
render_unit() {  # $1 = unit file; renders User/Group and SocketUser/SocketGroup
  sed -e "s/^User=vossi$/User=$USER/" -e "s/^Group=vossi$/Group=$RUN_GROUP/" \
      -e "s/^SocketUser=vossi$/SocketUser=$USER/" -e "s/^SocketGroup=vossi$/SocketGroup=$RUN_GROUP/" \
      "$SVC_DIR/deploy/$1"
}
changed=0
proxy_changed=0
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer \
         dvw-docker-proxy.socket dvw-docker-proxy.service; do
  rendered="$(mktemp)"
  render_unit "$u" > "$rendered"
  # Units are 0644, so the comparison needs no sudo; only installing a
  # changed one does, and that is outside the passwordless drop-in.
  if ! cmp -s "$rendered" "/etc/systemd/system/$u"; then
    if ! sudo -n install -m 0644 "$rendered" "/etc/systemd/system/$u"; then
      echo "ERROR: $u changed and installing it needs a password." >&2
      echo "       Re-run from a terminal (ssh -t), or run host-install.sh." >&2
      rm -f "$rendered"
      exit 1
    fi
    changed=1
    case "$u" in
      dvw-docker-proxy.*) proxy_changed=1 ;;
    esac
  fi
  rm -f "$rendered"
done
if [ "$changed" = 1 ]; then
  sudo systemctl daemon-reload
  # A changed unit may carry a changed [Install] (WantedBy=), and daemon-reload
  # does NOT rewrite enablement symlinks — only reenable does. Use sudo -n: a
  # host installed before the sudoers drop-in gained `reenable` would otherwise
  # sit at a password prompt in what is meant to be a hands-off update.
  if ! sudo -n systemctl reenable dvw-catalog.service >/dev/null 2>&1; then
    echo "WARN: could not reenable dvw-catalog.service without a password." >&2
    echo "      [Install] changes (e.g. WantedBy=docker.service) are NOT active." >&2
    echo "      Run once:  sudo systemctl reenable dvw-catalog.service" >&2
    echo "      (or re-run host-install.sh to refresh the sudoers drop-in)" >&2
  fi
fi

if [ "$proxy_changed" = 1 ]; then
  # A changed unit may carry a changed [Install] (e.g. SocketMode), so
  # reenable it the same way the catalog unit is reenabled above.
  if ! sudo -n systemctl reenable dvw-docker-proxy.socket >/dev/null 2>&1; then
    echo "WARN: could not reenable dvw-docker-proxy.socket without a password." >&2
    echo "      Run once:  sudo systemctl reenable dvw-docker-proxy.socket" >&2
    echo "      (or re-run host-install.sh to refresh the sudoers drop-in)" >&2
  fi
fi

# Stop the service, then restart the socket: a running service keeps its old
# listener even after the socket unit is rewritten. Run both unconditionally
# (not `A || B` short-circuited) so a failed stop never skips the socket
# restart, and combine their statuses into one WARN.
restart_proxy() {
  local rc=0
  sudo -n systemctl stop dvw-docker-proxy.service >/dev/null 2>&1 || rc=1
  sudo -n systemctl restart dvw-docker-proxy.socket >/dev/null 2>&1 || rc=1
  return "$rc"
}

if [ "$proxy_changed" = 1 ]; then
  if ! restart_proxy; then
    echo "WARN: could not restart dvw-docker-proxy.socket without a password." >&2
    echo "      Run once:  sudo systemctl stop dvw-docker-proxy.service && sudo systemctl restart dvw-docker-proxy.socket" >&2
    echo "      (or re-run host-install.sh to refresh the sudoers drop-in)" >&2
  fi
fi

# The proxy's own code can change without either unit file changing (a git
# pull that touches proxy/dvw_docker_proxy.py). Restart it the same way.
if ! git -C "$CHECKOUT" diff --quiet "HEAD@{1}" HEAD -- catalog-service/proxy 2>/dev/null; then
  if ! restart_proxy; then
    echo "WARN: proxy code changed but could not restart dvw-docker-proxy without a password." >&2
    echo "      Run once:  sudo systemctl stop dvw-docker-proxy.service && sudo systemctl restart dvw-docker-proxy.socket" >&2
  fi
fi

echo "==> restart"
sudo systemctl restart dvw-catalog.service

echo "==> smoke test"
PROXY_SOCK="/run/dvw-docker-proxy/docker.sock"
if [ ! -S "$PROXY_SOCK" ]; then
  echo "smoke test FAILED: $PROXY_SOCK is missing." >&2
  echo "  This host has not run the new installer yet. Run once:" >&2
  echo "  $SVC_DIR/deploy/host-install.sh" >&2
  exit 1
fi
if ! curl -fsS --max-time 2 --unix-socket "$PROXY_SOCK" http://localhost/_ping >/dev/null; then
  echo "smoke test FAILED: $PROXY_SOCK did not answer /_ping." >&2
  echo "  sudo systemctl status dvw-docker-proxy.socket dvw-docker-proxy.service" >&2
  echo "  journalctl -xeu dvw-docker-proxy.service | tail -50" >&2
  exit 1
fi
# Poll QUIETLY until the socket answers: `systemctl restart` returns once the
# unit execs, but uvicorn needs ~1s to bind $SOCK, so the first attempt(s) fail
# by design. Suppress those expected per-attempt curl errors (no misleading
# "connect to localhost port 80" noise) and only surface diagnostics if the
# service genuinely never comes up within the budget.
ok=0
for _ in $(seq 1 10); do
  if body=$(curl -fsS --unix-socket "$SOCK" http://localhost/v1/health 2>/dev/null); then
    printf '%s\n' "$body"; ok=1; break
  fi
  sleep 0.5
done
if [ "$ok" != 1 ]; then
  echo "smoke test FAILED — service did not answer on $SOCK after ~5s" >&2
  echo "  sudo systemctl status dvw-catalog.service" >&2
  echo "  journalctl -xeu dvw-catalog.service | tail -50" >&2
  exit 1
fi
echo "update ok"
