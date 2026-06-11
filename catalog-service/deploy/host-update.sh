#!/usr/bin/env bash
# Update dvw-catalog ON vossisrv: git pull + uv sync + restart. One command.
# Run as `vossi` on vossisrv (restart is passwordless via the sudoers drop-in
# that host-install.sh laid down).
#
#   /opt/dvw/catalog-service/deploy/host-update.sh
set -euo pipefail

CHECKOUT="${CHECKOUT:-/opt/dvw}"
SVC_DIR="$CHECKOUT/catalog-service"
SOCK="/run/dvw-catalog/catalog.sock"

echo "==> git pull"
git -C "$CHECKOUT" pull --ff-only

echo "==> uv sync --frozen"
export PATH="$HOME/.local/bin:$PATH"
( cd "$SVC_DIR" && uv sync --frozen --no-dev )

# Reinstall units if they changed in this pull. Render User=/Group= for the
# running user — same as host-install.sh — so an update never reverts the
# template back to the committed `vossi` default (and we compare the RENDERED
# unit, not the raw file, so a non-vossi install doesn't reinstall every time).
RUN_GROUP="$(id -gn)"
changed=0
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer; do
  rendered="$(mktemp)"
  sed -e "s/^User=vossi$/User=$USER/" -e "s/^Group=vossi$/Group=$RUN_GROUP/" \
      "$SVC_DIR/deploy/$u" > "$rendered"
  if ! sudo cmp -s "$rendered" "/etc/systemd/system/$u"; then
    sudo install -m 0644 "$rendered" "/etc/systemd/system/$u"; changed=1
  fi
  rm -f "$rendered"
done
[ "$changed" = 1 ] && sudo systemctl daemon-reload

echo "==> restart"
sudo systemctl restart dvw-catalog.service

echo "==> smoke test"
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
