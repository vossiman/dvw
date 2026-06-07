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

step "checking apt dependencies (jq)"
NEEDED=()
for pkg in jq; do
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
if dvw_write_version_marker "$SCRIPT_DIR"; then
  _dvw_ver=$(dvw_installed_version)
  [ -n "$_dvw_ver" ] && echo "recorded dvw version $_dvw_ver"
fi

step "first-run catalog init (catalog service health check)"
# shellcheck source=lib/catalog.sh
. "$SCRIPT_DIR/lib/catalog.sh"
# Warn-and-continue: an unreachable service must not abort the install (the
# client just needs SSH access to vossisrv, which may not be set up yet).
catalog_init_if_missing || echo "  (catalog service not reachable yet — set up SSH access to the box, then run: dvw doctor)"

step "ssh blueprint sync (Include + first refresh)"
# shellcheck source=lib/ssh-sync.sh
. "$SCRIPT_DIR/lib/ssh-sync.sh"
# Warn-and-continue: ssh_sync_init returns non-zero if the catalog service is
# unreachable; don't let that abort the install under set -e.
ssh_sync_init || echo "  (ssh blueprint not synced — catalog service unreachable; re-run dvw-install.sh once SSH access is set up)"

echo
echo "✓ install complete. Try: dvw doctor"
