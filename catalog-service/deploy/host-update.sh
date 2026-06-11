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
# Retry briefly: restart returns once the unit execs, but uvicorn may not have
# bound $SOCK yet. On real failure, point at the upstream diagnostics instead of
# letting curl's misleading "connect to localhost port 80" be the last word.
for i in 1 2 3; do
  curl -fsS --unix-socket "$SOCK" http://localhost/v1/health && break
  if [ "$i" = 3 ]; then
    echo >&2
    echo "smoke test FAILED — service did not answer on $SOCK" >&2
    echo "  sudo systemctl status dvw-catalog.service" >&2
    echo "  journalctl -xeu dvw-catalog.service | tail -50" >&2
    exit 1
  fi
  sleep 1
done
echo
echo "update ok"
