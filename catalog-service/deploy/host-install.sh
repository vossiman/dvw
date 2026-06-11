#!/usr/bin/env bash
# One-time install of dvw-catalog ON vossisrv from a local git checkout of the
# dvw repo. After this, updates are just `deploy/host-update.sh` (git pull +
# restart) — no laptop, no rsync.
#
# Run as `vossi` on vossisrv — NOT with sudo. The script runs as your normal
# user (it clones, builds the venv, and owns the data dir as $USER) and calls
# `sudo` itself only for the steps that touch system paths. You do NOT need to
# pre-create any directories; in particular do not `mkdir /opt/dvw-catalog` — it
# is a symlink this script manages (a real dir there breaks the service).
#
# Bootstrap (copy-paste). `/opt` isn't writable by your user, so create the
# checkout dir with correct ownership in one sudo — do NOT `chown -R` by hand:
#     sudo install -d -o "$USER" -g "$USER" /opt/dvw
#     git clone -b main https://github.com/vossiman/dvw.git /opt/dvw
#     /opt/dvw/catalog-service/deploy/host-install.sh
# (until PR #9 merges, clone -b feat/catalog-service-client, or pass BRANCH=…)
# Re-run any time to reconfigure — it's idempotent.
#
# Overridable via env:
#   REPO_URL   default https://github.com/vossiman/dvw.git  (HTTPS works with no
#              SSH keys on the box; set REPO_URL=git@github.com:vossiman/dvw.git
#              to use SSH, which needs a key configured on this host)
#   BRANCH     default main          (use feat/catalog-service-client until PR #9 merges)
#   CHECKOUT   default /opt/dvw
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/vossiman/dvw.git}"
BRANCH="${BRANCH:-main}"
CHECKOUT="${CHECKOUT:-/opt/dvw}"
SVC_DIR="$CHECKOUT/catalog-service"
APP_LINK="/opt/dvw-catalog"          # stable path the systemd unit references
DATA_DIR="/var/lib/dvw-catalog"
SOCK="/run/dvw-catalog/catalog.sock"

# Must run as the normal user, not root. The venv/checkout are owned by $USER
# and the service runs as User=vossi; a root-owned install breaks it, and the
# sudoers drop-in below is keyed to your login. The script sudo's where needed.
if [ "$(id -u)" -eq 0 ]; then
  echo "error: run this as your normal user, not root/sudo." >&2
  echo "       it will invoke sudo itself for the steps that need it." >&2
  exit 1
fi
# Prime sudo up front: fail fast now if you lack sudo rights, and avoid a
# password prompt stalling the install halfway through.
echo "==> 0/7 installer needs sudo for /opt, /var/lib, /etc/systemd and sudoers; priming…"
sudo -v

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
# $APP_LINK must be a symlink. If a previous run or a manual `mkdir` left a real
# directory here, `ln -sfn` would silently create the link *inside* it
# ($APP_LINK/catalog-service) instead of replacing it, and the unit's ExecStart
# (=$APP_LINK/.venv/bin/uvicorn) would fail with status=203/EXEC. Replace
# anything that isn't already a symlink before (re)creating it.
if [ -e "$APP_LINK" ] && [ ! -L "$APP_LINK" ]; then
  echo "    $APP_LINK exists as a real path; replacing it with the symlink"
  sudo rm -rf "$APP_LINK"
fi
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
# The committed units default to User=vossi/Group=vossi; render them for whoever
# is installing so the service isn't tied to a specific account. Usernames/group
# names are [A-Za-z0-9_-] so they're safe in the sed replacement.
RUN_GROUP="$(id -gn)"
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer; do
  sed -e "s/^User=vossi$/User=$USER/" -e "s/^Group=vossi$/Group=$RUN_GROUP/" \
      "$SVC_DIR/deploy/$u" | sudo install -m 0644 /dev/stdin "/etc/systemd/system/$u"
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
# Retry briefly: the unit binds $SOCK at startup, so there's a small race
# between `enable --now` returning and the socket being ready. On real failure,
# point at the upstream diagnostics rather than letting curl's misleading
# "connect to localhost port 80" message be the last word.
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
echo "install ok — update later with: $SVC_DIR/deploy/host-update.sh"
