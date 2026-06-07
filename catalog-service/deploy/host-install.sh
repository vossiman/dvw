#!/usr/bin/env bash
# One-time install of dvw-catalog ON vossisrv from a local git checkout of the
# dvw repo. After this, updates are just `deploy/host-update.sh` (git pull +
# restart) — no laptop, no rsync.
#
# Run as `vossi` on vossisrv:
#     git clone -b main git@github.com:vossiman/dvw.git /opt/dvw \
#       && /opt/dvw/catalog-service/deploy/host-install.sh
# (until PR #9 merges, clone -b feat/catalog-service-client, or pass BRANCH=…)
# Re-run any time to reconfigure — it's idempotent.
#
# Overridable via env:
#   REPO_URL   default git@github.com:vossiman/dvw.git
#   BRANCH     default main          (use feat/catalog-service-client until PR #9 merges)
#   CHECKOUT   default /opt/dvw
set -euo pipefail

REPO_URL="${REPO_URL:-git@github.com:vossiman/dvw.git}"
BRANCH="${BRANCH:-main}"
CHECKOUT="${CHECKOUT:-/opt/dvw}"
SVC_DIR="$CHECKOUT/catalog-service"
APP_LINK="/opt/dvw-catalog"          # stable path the systemd unit references
DATA_DIR="/var/lib/dvw-catalog"
SOCK="/run/dvw-catalog/catalog.sock"

echo "==> 1/7 checkout ($BRANCH -> $CHECKOUT)"
if [ ! -d "$CHECKOUT/.git" ]; then
  sudo install -d -o "$USER" -g "$USER" "$(dirname "$CHECKOUT")"
  git clone --branch "$BRANCH" "$REPO_URL" "$CHECKOUT"
else
  git -C "$CHECKOUT" fetch origin "$BRANCH"
  git -C "$CHECKOUT" checkout "$BRANCH"
  git -C "$CHECKOUT" pull --ff-only
fi

echo "==> 2/7 stable symlink $APP_LINK -> $SVC_DIR"
sudo ln -sfn "$SVC_DIR" "$APP_LINK"

echo "==> 3/7 data dir + git backup repo ($DATA_DIR)"
sudo install -d -o "$USER" -g "$USER" -m 0750 "$DATA_DIR"
if [ ! -d "$DATA_DIR/.git" ]; then
  git -C "$DATA_DIR" init -q
  git -C "$DATA_DIR" config user.email "dvw-catalog@vossisrv"
  git -C "$DATA_DIR" config user.name  "dvw-catalog"
fi

echo "==> 4/7 venv (uv sync --frozen)"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
( cd "$SVC_DIR" && uv sync --frozen --no-dev )

echo "==> 5/7 env file (once)"
[ -f "$SVC_DIR/catalog.env" ] || \
  install -m 0640 "$SVC_DIR/deploy/catalog.env.example" "$SVC_DIR/catalog.env"

echo "==> 6/7 systemd units + passwordless-restart sudoers"
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer; do
  sudo install -m 0644 "$SVC_DIR/deploy/$u" "/etc/systemd/system/$u"
done
# Narrow drop-in so host-update.sh can restart without a password prompt.
# Scoped to exactly these three commands on this one unit. Comment out the
# install below if you'd rather type your sudo password on each update.
sudo install -m 0440 /dev/stdin /etc/sudoers.d/dvw-catalog <<SUDO
$USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart dvw-catalog.service, /usr/bin/systemctl status dvw-catalog.service, /usr/bin/systemctl daemon-reload
SUDO
sudo systemctl daemon-reload
sudo systemctl enable --now dvw-catalog.service
sudo systemctl enable --now dvw-catalog-backup.timer

echo "==> 7/7 smoke test"
curl -fsS --unix-socket "$SOCK" http://localhost/v1/health; echo
echo "install ok — update later with: $SVC_DIR/deploy/host-update.sh"
