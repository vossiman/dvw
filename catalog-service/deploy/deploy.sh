#!/usr/bin/env bash
# Idempotent deploy of dvw-catalog to vossisrv. Run from a laptop.
#
#   ./deploy/deploy.sh                 # deploy to vossi@vossisrv
#   REMOTE=vossi@host ./deploy/deploy.sh
#
# Strategy: rsync the source tree to /opt/dvw-catalog (no git/creds on the
# server), `uv sync --frozen` the venv, install the systemd unit only when it
# changed, (re)start, then smoke-test over the same unix socket clients use.
set -euo pipefail

REMOTE="${REMOTE:-vossi@vossisrv}"
APP_DIR=/opt/dvw-catalog
DATA_DIR=/var/lib/dvw-catalog
SOCK=/run/dvw-catalog/catalog.sock
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> syncing $HERE -> $REMOTE:$APP_DIR"
rsync -az --delete \
  --exclude '.venv' --exclude '__pycache__' --exclude '.git' \
  --exclude '.pytest_cache' --exclude 'catalog.env' \
  "$HERE/" "$REMOTE:$APP_DIR/"

echo "==> remote install + restart"
ssh "$REMOTE" bash -seuo pipefail <<'REMOTE_EOF'
  APP_DIR=/opt/dvw-catalog
  DATA_DIR=/var/lib/dvw-catalog

  # Data dir owned by the service user (created once; idempotent).
  sudo install -d -o vossi -g vossi -m 0750 "$DATA_DIR"

  # Make the data dir a git repo for the nightly backup timer (no-op if present).
  if [ ! -d "$DATA_DIR/.git" ]; then
    git -C "$DATA_DIR" init -q
    git -C "$DATA_DIR" config user.email "dvw-catalog@vossisrv"
    git -C "$DATA_DIR" config user.name "dvw-catalog"
  fi

  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"

  cd "$APP_DIR"
  uv sync --frozen --no-dev 2>/dev/null || uv sync --no-dev

  # Install/refresh units only when changed, then reload.
  changed=0
  for unit in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer; do
    if ! sudo cmp -s "$APP_DIR/deploy/$unit" "/etc/systemd/system/$unit"; then
      sudo install -m 0644 "$APP_DIR/deploy/$unit" "/etc/systemd/system/$unit"
      changed=1
    fi
  done
  [ "$changed" = 1 ] && sudo systemctl daemon-reload

  [ -f "$APP_DIR/catalog.env" ] || \
    sudo install -o vossi -g vossi -m 0640 \
      "$APP_DIR/deploy/catalog.env.example" "$APP_DIR/catalog.env"

  sudo systemctl enable dvw-catalog.service >/dev/null
  sudo systemctl restart dvw-catalog.service
  sudo systemctl enable --now dvw-catalog-backup.timer >/dev/null
  sudo systemctl --no-pager --lines=0 status dvw-catalog.service || true
REMOTE_EOF

echo "==> smoke test"
ssh "$REMOTE" -- curl -fsS --unix-socket "$SOCK" http://localhost/v1/health
echo
echo "deploy ok"
