#!/usr/bin/env bash
# Idempotent bootstrap for dvw on Mint or WSL Ubuntu.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TARGET_BIN="$HOME/.local/bin/dvw"

is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

step() { echo; echo "▸ $*"; }

step "checking apt dependencies"
NEEDED=()
for pkg in jq fuse3 rclone; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEEDED+=("$pkg")
done
if (( ${#NEEDED[@]} )); then
  echo "installing: ${NEEDED[*]}"
  sudo apt update
  sudo apt install -y "${NEEDED[@]}"
fi

step "checking gum"
if ! command -v gum >/dev/null; then
  echo "installing gum from Charm apt repo"
  sudo mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/charm.gpg ]]; then
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/charm.list ]]; then
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list
  fi
  sudo apt update
  sudo apt install -y gum
fi

step "checking devpod"
if ! command -v devpod >/dev/null; then
  echo "installing devpod"
  curl -L -o /tmp/devpod \
    "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64"
  sudo install -m 0755 /tmp/devpod /usr/local/bin/devpod
fi

if is_wsl; then
  step "WSL detected: checking systemd"
  if [[ ! -f /etc/wsl.conf ]] || ! grep -q '^systemd=true' /etc/wsl.conf; then
    echo "writing /etc/wsl.conf to enable systemd"
    sudo tee /etc/wsl.conf >/dev/null <<'CONF'
[boot]
systemd=true
CONF
    echo
    echo "==> systemd is now enabled, but WSL must be restarted before it takes effect."
    echo "==> From Windows PowerShell, run: wsl --shutdown"
    echo "==> Then re-open WSL and re-run this installer."
    exit 0
  fi
  if ! systemctl --user >/dev/null 2>&1; then
    echo "systemctl --user does not work yet — likely WSL has not been shut down/restarted since enabling systemd."
    echo "From Windows PowerShell: wsl --shutdown ; then re-open WSL and re-run."
    exit 1
  fi
fi

step "checking rclone Dropbox remote"
if ! rclone listremotes 2>/dev/null | grep -qx 'dropbox:'; then
  echo "no 'dropbox:' rclone remote configured"
  echo "run: rclone config"
  echo "  → n (new remote), name = dropbox, type = dropbox"
  echo "  → follow OAuth prompts, then re-run this installer"
  exit 1
fi

step "installing systemd user unit"
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$SCRIPT_DIR/systemd/rclone-dropbox.service" \
  "$HOME/.config/systemd/user/rclone-dropbox.service"
mkdir -p "$HOME/Dropbox-remote"
systemctl --user daemon-reload
systemctl --user enable --now rclone-dropbox.service

step "waiting for rclone mount to come up"
for _ in $(seq 1 15); do
  if mountpoint -q "$HOME/Dropbox-remote"; then break; fi
  sleep 1
done
if ! mountpoint -q "$HOME/Dropbox-remote"; then
  echo "rclone mount did not appear within 15s. Check:"
  echo "  systemctl --user status rclone-dropbox"
  echo "Re-run this installer once the mount is live."
  exit 1
fi
systemctl --user status rclone-dropbox.service --no-pager || true

step "installing dvw to $TARGET_BIN"
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT_DIR/dvw" "$TARGET_BIN"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "WARNING: $HOME/.local/bin is not on PATH; add it to your shell rc" ;;
esac

step "first-run catalog init"
mkdir -p "$HOME/Dropbox-remote/dvw"
"$TARGET_BIN" -l >/dev/null

echo
echo "✓ install complete. Try: dvw doctor"
