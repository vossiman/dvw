#!/usr/bin/env bash
# Idempotent bootstrap for dvw on Mint or WSL Ubuntu.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TARGET_BIN="$HOME/.local/bin/dvw"

# --check-only: verify idempotency invariants without modifying the host.
# Used by tests/bats/install.bats and as a self-diagnostic.
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
  esac
done

if (( CHECK_ONLY )); then
  echo "▸ dvw-install.sh --check-only: verifying invariants (no host writes)"
  # 1. The script's resolved location is reachable.
  [[ -x "$SCRIPT_DIR/dvw" ]] || { echo "ERROR: $SCRIPT_DIR/dvw not executable"; exit 1; }
  # 2. The PATH symlink, if present, points at the right binary.
  if [[ -L "$HOME/.local/bin/dvw" ]]; then
    target=$(readlink -f "$HOME/.local/bin/dvw")
    expected=$(readlink -f "$SCRIPT_DIR/dvw")
    if [[ "$target" != "$expected" ]]; then
      echo "WARN: ~/.local/bin/dvw points at $target, not $expected (this is OK if you have multiple checkouts)"
    fi
  fi
  echo "▸ dvw-install.sh --check-only: invariants OK"
  exit 0
fi

is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

step() { echo; echo "▸ $*"; }

step "checking apt dependencies (jq, fuse3)"
NEEDED=()
for pkg in jq fuse3; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEEDED+=("$pkg")
done
if (( ${#NEEDED[@]} )); then
  echo "installing: ${NEEDED[*]}"
  sudo apt update
  sudo apt install -y "${NEEDED[@]}"
fi

step "checking rclone (upstream installer; not apt)"
# Ubuntu noble ships rclone 1.60.1 (late 2022). Upstream is 1.74+. Older
# versions have FUSE/Dropbox stability bugs. Install (or replace apt
# version with) the upstream binary unconditionally if too old/missing.
NEED_RCLONE=1
if command -v rclone >/dev/null; then
  RCLONE_VER=$(rclone --version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//;s/-.*//')
  RCLONE_MAJOR=${RCLONE_VER%%.*}
  RCLONE_MINOR=$(echo "$RCLONE_VER" | cut -d. -f2)
  if (( RCLONE_MAJOR > 1 )) || { (( RCLONE_MAJOR == 1 )) && (( ${RCLONE_MINOR:-0} >= 65 )); }; then
    NEED_RCLONE=0
  else
    echo "found rclone $RCLONE_VER — too old; will replace with upstream"
    # Apt's rclone owns /usr/bin/rclone; remove it before the upstream
    # installer drops in (which also writes to /usr/bin/rclone). This avoids
    # the trap where a later `apt remove rclone` would delete the upstream
    # binary because dpkg still owns the path.
    if dpkg -s rclone >/dev/null 2>&1; then
      sudo apt remove -y rclone
    fi
  fi
fi
if (( NEED_RCLONE )); then
  echo "installing rclone via https://rclone.org/install.sh"
  curl -fsSL https://rclone.org/install.sh | sudo bash
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

# On Ubuntu/Mint with "Encrypt Home" (ecryptfs), linger=yes makes the
# user systemd manager start at boot — before pam_ecryptfs has decrypted
# ~/.config — so this unit's default.target.wants symlink is invisible
# and the mount never auto-starts. Disable linger so user@UID.service
# starts at login (after ecryptfs unwrap). LP #1746527 / #1734290.
if findmnt -no FSTYPE "$HOME" 2>/dev/null | grep -qx ecryptfs \
   && [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then
  echo "encrypted home + linger=yes is incompatible; disabling linger"
  loginctl disable-linger "$USER"
fi

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

# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
step "recording dvw version marker"
dvw_write_version_marker "$SCRIPT_DIR" \
  && echo "recorded dvw version $(dvw_installed_version)"

step "first-run catalog init"
mkdir -p "$HOME/Dropbox-remote/dvw"
"$TARGET_BIN" -l >/dev/null

step "ssh blueprint sync (Include + first refresh)"
# shellcheck source=lib/ssh-sync.sh
. "$SCRIPT_DIR/lib/ssh-sync.sh"
ssh_sync_init

echo
echo "✓ install complete. Try: dvw doctor"
