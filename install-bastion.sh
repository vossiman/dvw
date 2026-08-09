#!/usr/bin/env bash
# install-bastion.sh — provision a dvw bastion (jumpi): a small always-on box
# (Raspberry Pi) that phones SSH into via Termius and that runs the full dvw
# client. Idempotent; re-run anytime. Spec: devMachine
# docs/superpowers/specs/2026-08-09-agent-waiting-phone-notify-design.md
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ONLY=0; [[ "${1:-}" == "--check" ]] && CHECK_ONLY=1
fail=0
ok()   { printf '[OK]   %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1"; fail=1; }

# Resolve the devpod binary: on PATH, or dropped into ~/.local/bin by an
# earlier run of this script (which may not have made it onto PATH yet in
# the current shell).
devpod_bin() {
  if command -v devpod >/dev/null 2>&1; then
    command -v devpod
  elif [[ -x "$HOME/.local/bin/devpod" ]]; then
    printf '%s\n' "$HOME/.local/bin/devpod"
  fi
}

# 1. devpod CLI (needed for the devpod ssh --stdio ProxyCommand)
DEVPOD="$(devpod_bin)"
if [[ -n "$DEVPOD" ]]; then
  ok "devpod binary present ($DEVPOD)"
else
  if (( CHECK_ONLY )) || [[ "${DVW_BASTION_SKIP_NETWORK:-}" == "1" ]]; then
    bad "devpod binary missing"
  else
    case "$(uname -m)" in
      aarch64|arm64) arch=arm64 ;;
      x86_64)        arch=amd64 ;;
      *) bad "unsupported arch $(uname -m)"; arch="" ;;
    esac
    if [[ -n "$arch" ]]; then
      mkdir -p "$HOME/.local/bin"
      curl -fsSL -o "$HOME/.local/bin/devpod" \
        "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-$arch"
      chmod +x "$HOME/.local/bin/devpod"
      DEVPOD="$HOME/.local/bin/devpod"
      ok "devpod installed to ~/.local/bin"
    fi
  fi
fi

# 2. dvw client itself (clone target = this checkout; installer is idempotent).
# Invoke by bare name with $HERE appended to PATH (rather than a hardcoded
# "$HERE/dvw-install.sh" path) so tests can shadow it with a stub earlier in
# PATH; in normal use nothing else provides "dvw-install.sh" so this checkout's
# copy is what runs.
if (( ! CHECK_ONLY )); then
  PATH="$PATH:$HERE" dvw-install.sh
  ok "dvw client installed/refreshed"
fi

# 3. Reachability report
if ssh -o BatchMode=yes -o ConnectTimeout=5 vossisrv true 2>/dev/null; then
  ok "vossisrv reachable via ssh"
else
  bad "vossisrv NOT reachable (key loaded? on the WireGuard/LAN?)"
fi
if [[ -n "$DEVPOD" ]] && "$DEVPOD" context list >/dev/null 2>&1; then
  ok "devpod context configured"
else
  bad "devpod context missing — run: devpod provider add ssh / import context"
fi

cat <<'EOF'

Next steps (manual, see docs/bastion.md):
 - Termius host "jumpi" -> this box, your normal key. Full dvw available.
 - Optional zero-keystroke attach: a SECOND keypair restricted in
   ~/.ssh/authorized_keys to:  command="dvw attach",no-port-forwarding,no-X11-forwarding <pubkey>
   and a second Termius host "jumpi ⏸" using that key.
EOF
exit "$fail"
