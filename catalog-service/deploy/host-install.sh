#!/usr/bin/env bash
# Install of dvw-catalog ON vossisrv from a local git checkout of the dvw repo.
# Idempotent and safe to re-run: it pulls, re-syncs the venv and RESTARTS the
# service, so a re-run genuinely picks up new code.
# For routine updates prefer `deploy/host-update.sh` (git pull +
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
# Re-run any time to reconfigure — it's idempotent.
#
# Overridable via env:
#   REPO_URL   default https://github.com/vossiman/dvw.git  (HTTPS works with no
#              SSH keys on the box; set REPO_URL=git@github.com:vossiman/dvw.git
#              to use SSH, which needs a key configured on this host)
#   BRANCH     default main
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
echo "==> 0/8 installer needs sudo for /opt, /var/lib, /etc/systemd and sudoers; priming…"
sudo -v

echo "==> 1/8 checkout ($BRANCH -> $CHECKOUT)"
if [ ! -d "$CHECKOUT/.git" ]; then
  sudo install -d -o "$USER" -g "$USER" "$(dirname "$CHECKOUT")"
  git clone --branch "$BRANCH" "$REPO_URL" "$CHECKOUT"
else
  git -C "$CHECKOUT" fetch origin "$BRANCH"
  git -C "$CHECKOUT" checkout "$BRANCH"
  git -C "$CHECKOUT" pull --ff-only
fi

echo "==> 2/8 stable symlink $APP_LINK -> $SVC_DIR"
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

echo "==> 3/8 data dir + git backup repo ($DATA_DIR)"
sudo install -d -o "$USER" -g "$USER" -m 0750 "$DATA_DIR"
if [ ! -d "$DATA_DIR/.git" ]; then
  git -C "$DATA_DIR" init -q
  git -C "$DATA_DIR" config user.email "dvw-catalog@$(hostname -s)"
  git -C "$DATA_DIR" config user.name  "dvw-catalog"
fi

echo "==> 4/8 venv (uv sync --frozen)"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
( cd "$SVC_DIR" && uv sync --frozen --no-dev )

echo "==> 5/8 env file (once)"
[ -f "$SVC_DIR/catalog.env" ] || \
  install -m 0640 "$SVC_DIR/deploy/catalog.env.example" "$SVC_DIR/catalog.env"

# The unit no longer has SupplementaryGroups=docker, so dvw-docker-proxy is
# the only Docker path. The installer needs no docker CLI access itself: the
# one place it touches docker is the guarded one-time retirement of the old
# tecnativa container below.
echo "==> 6/8 dvw-docker-proxy (system user + socket-activated unit)"
PROXY_SOCK="/run/dvw-docker-proxy/docker.sock"
if ! id dvw-proxy >/dev/null 2>&1; then
  # --user-group: don't rely on USERGROUPS_ENAB=yes (a login.defs default
  # that a hardened host may turn off) to get the dvw-proxy group the
  # service's Group=dvw-proxy needs.
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group --groups docker dvw-proxy
fi
# Retire the tecnativa compose proxy if a previous install left it running.
# The compose file is gone from the checkout, so address the container by
# the name compose gave it (project "deploy", service "docker-proxy").
# "docker is unreachable" and "the container is gone" are different answers,
# and only one of them means there is nothing to do. The installing user may
# already have been removed from the docker group (that is the end state this
# migration wants), in which case `docker ps` fails and the retirement has to
# be handed to the operator instead of being silently skipped.
if command -v docker >/dev/null 2>&1; then
  if docker_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
    if printf '%s\n' "$docker_names" | grep -qx 'deploy-docker-proxy-1'; then
      echo "    removing the retired tecnativa docker-socket-proxy container"
      docker rm -f deploy-docker-proxy-1 >/dev/null
    fi
  else
    echo "WARN: docker is installed but not reachable as $USER, so the retired" >&2
    echo "      tecnativa container could not be checked. Remove it by hand:" >&2
    echo "      sudo docker rm -f deploy-docker-proxy-1" >&2
  fi
fi
# Point the catalog at the proxy socket. Rewrite a tcp:// value left by the
# previous proxy, and an empty value (config.py now refuses one); add the key
# when it is missing; leave any other value alone.
if grep -q '^CATALOG_DOCKER_HOST=tcp://' "$SVC_DIR/catalog.env"; then
  sed -i "s|^CATALOG_DOCKER_HOST=tcp://.*|CATALOG_DOCKER_HOST=unix://$PROXY_SOCK|" "$SVC_DIR/catalog.env"
elif grep -q '^CATALOG_DOCKER_HOST=[[:space:]]*$' "$SVC_DIR/catalog.env"; then
  sed -i "s|^CATALOG_DOCKER_HOST=[[:space:]]*$|CATALOG_DOCKER_HOST=unix://$PROXY_SOCK|" "$SVC_DIR/catalog.env"
elif ! grep -q '^CATALOG_DOCKER_HOST=' "$SVC_DIR/catalog.env"; then
  printf '\nCATALOG_DOCKER_HOST=unix://%s\n' "$PROXY_SOCK" >> "$SVC_DIR/catalog.env"
fi

echo "==> 7/8 systemd units + passwordless-restart sudoers"
# The committed units default to User=vossi/Group=vossi; render them for whoever
# is installing so the service isn't tied to a specific account. Usernames/group
# names are [A-Za-z0-9_-] so they're safe in the sed replacement.
RUN_GROUP="$(id -gn)"
render_unit() {  # $1 = unit file; renders User/Group and SocketUser/SocketGroup
  sed -e "s/^User=vossi$/User=$USER/" -e "s/^Group=vossi$/Group=$RUN_GROUP/" \
      -e "s/^SocketUser=vossi$/SocketUser=$USER/" -e "s/^SocketGroup=vossi$/SocketGroup=$RUN_GROUP/" \
      "$SVC_DIR/deploy/$1"
}
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer \
         dvw-docker-proxy.socket dvw-docker-proxy.service; do
  render_unit "$u" | sudo install -m 0644 /dev/stdin "/etc/systemd/system/$u"
done
# Narrow drop-in so host-update.sh can restart without a password prompt.
# Scoped to exactly these commands on these units. Comment out the install
# below if you'd rather type your sudo password on each update.
sudo install -m 0440 /dev/stdin /etc/sudoers.d/dvw-catalog <<SUDO
$USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart dvw-catalog.service, /usr/bin/systemctl status dvw-catalog.service, /usr/bin/systemctl reenable dvw-catalog.service, /usr/bin/systemctl daemon-reload, /usr/bin/systemctl stop dvw-docker-proxy.service, /usr/bin/systemctl restart dvw-docker-proxy.socket, /usr/bin/systemctl restart dvw-docker-proxy.service, /usr/bin/systemctl status dvw-docker-proxy.service, /usr/bin/systemctl reenable dvw-docker-proxy.socket
SUDO
sudo systemctl daemon-reload
sudo systemctl reenable dvw-docker-proxy.socket
# A running service keeps its old listener even after the socket unit is
# rewritten, so always stop the service before restarting the socket.
sudo systemctl stop dvw-docker-proxy.service
sudo systemctl restart dvw-docker-proxy.socket
echo "==> waiting for the proxy socket to answer"
proxy_ok=""
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 --unix-socket "$PROXY_SOCK" http://localhost/_ping >/dev/null 2>&1; then
    proxy_ok=1; break
  fi
  sleep 1
done
if [[ -z "$proxy_ok" ]]; then
  echo "ERROR: dvw-docker-proxy did not answer on $PROXY_SOCK after 30s." >&2
  echo "       sudo systemctl status dvw-docker-proxy.socket dvw-docker-proxy.service" >&2
  echo "       journalctl -xeu dvw-docker-proxy.service | tail -50" >&2
  exit 1
fi
echo "==> proxy healthy"
# The retired tecnativa proxy published 127.0.0.1:2375, an unauthenticated
# Docker API on the loopback interface. If something is still listening there
# the migration is not finished, whatever this installer managed to do. Warn
# loudly, but do not fail: the new proxy is up and the catalog works.
if ss -ltn 2>/dev/null | grep -q '127.0.0.1:2375'; then
  echo "WARN: something still listens on 127.0.0.1:2375 (the retired tecnativa" >&2
  echo "      docker-socket-proxy). Stop and remove it:" >&2
  echo "      sudo docker rm -f deploy-docker-proxy-1" >&2
  echo "      then re-check with:  ss -ltn | grep 127.0.0.1:2375" >&2
fi
# enable --now STARTS an inactive unit but does NOT restart a running one, so
# re-running this installer against a live service left the old code serving
# while the checkout and venv were already updated — and the smoke test below
# passes either way, because /v1/health exists in both builds. Enable, then
# restart unconditionally: the whole point of a re-run is to pick up new code.
# `restart` starts a stopped unit too, so this is correct on first install.
# reenable, not enable: it REWRITES the [Install] symlinks instead of only
# adding missing ones, so a change to WantedBy= (e.g. adding
# docker.service) actually lands on hosts installed before that change.
# On a not-yet-enabled unit it behaves exactly like enable.
sudo systemctl reenable dvw-catalog.service
sudo systemctl restart dvw-catalog.service
sudo systemctl enable --now dvw-catalog-backup.timer

echo "==> 8/8 smoke test"
# Poll QUIETLY until the socket answers: the unit binds $SOCK ~1s after
# `enable --now` returns, so the first attempt(s) fail by design. Suppress those
# expected per-attempt curl errors (no misleading "connect to localhost port 80"
# noise) and only surface diagnostics if the service genuinely never comes up.
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
echo "install ok — update later with: $SVC_DIR/deploy/host-update.sh"
