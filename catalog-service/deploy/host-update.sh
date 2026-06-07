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

# Reinstall units if they changed in this pull.
changed=0
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer; do
  if ! sudo cmp -s "$SVC_DIR/deploy/$u" "/etc/systemd/system/$u"; then
    sudo install -m 0644 "$SVC_DIR/deploy/$u" "/etc/systemd/system/$u"; changed=1
  fi
done
[ "$changed" = 1 ] && sudo systemctl daemon-reload

echo "==> restart"
sudo systemctl restart dvw-catalog.service

echo "==> smoke test"
curl -fsS --unix-socket "$SOCK" http://localhost/v1/health; echo
echo "update ok"
