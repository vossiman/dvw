#!/usr/bin/env bash
# install-bastion.sh — provision a dvw bastion (jumpi): a small always-on box
# (Raspberry Pi) that phones SSH into via Termius and that runs the full dvw
# client. Idempotent; re-run anytime. Spec: devMachine
# docs/superpowers/specs/2026-08-09-agent-waiting-phone-notify-design.md
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/managed-install.sh
. "$HERE/lib/managed-install.sh"
CHECK_ONLY=0
UNATTENDED=0
MANAGED_SOURCE=""
MANAGED_VERSION=""
while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --unattended) UNATTENDED=1; shift ;;
    --source) MANAGED_SOURCE="${2:-}"; shift 2 ;;
    --version) MANAGED_VERSION="${2:-}"; shift 2 ;;
    *) echo "usage: install-bastion.sh [--check] [--unattended --source PATH --version SHA]" >&2; exit 2 ;;
  esac
done
if (( UNATTENDED )) && [[ -z "$MANAGED_SOURCE" || -z "$MANAGED_VERSION" ]]; then
  echo "usage: install-bastion.sh --unattended --source PATH --version SHA" >&2
  exit 2
fi

# The common runtime is installed by aiCodingBaseSetup's minimal Pi bootstrap,
# before it delegates the selected dvw snapshot here.  Keep this boundary
# small: dvw owns its client activation, then asks the already-installed
# common worker to enroll/ensure the schedule.  The Pi bootstrap's component
# inventory is what limits that worker to dvw and the common runtime.
AUTO_UPDATE=""
if (( UNATTENDED )); then
  if command -v aicoding-auto-update >/dev/null 2>&1; then
    AUTO_UPDATE="$(command -v aicoding-auto-update)"
  elif [[ -x "$HOME/.local/bin/aicoding-auto-update" ]]; then
    AUTO_UPDATE="$HOME/.local/bin/aicoding-auto-update"
  else
    echo "minimal common updater missing; install it before Pi enrollment" >&2
    exit 1
  fi
fi
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
    if devpod_url=$(dvw_devpod_download_url); then
      mkdir -p "$HOME/.local/bin"
      curl -fsSL -o "$HOME/.local/bin/devpod" \
        "$devpod_url"
      chmod +x "$HOME/.local/bin/devpod"
      DEVPOD="$HOME/.local/bin/devpod"
      ok "devpod installed to ~/.local/bin"
    else
      bad "unsupported arch $(uname -m)"
    fi
  fi
fi

# 2. dvw client itself (clone target = this checkout; installer is idempotent).
# Invoke by bare name with $HERE appended to PATH (rather than a hardcoded
# "$HERE/dvw-install.sh" path) so tests can shadow it with a stub earlier in
# PATH; in normal use nothing else provides "dvw-install.sh" so this checkout's
# copy is what runs.
if (( ! CHECK_ONLY )); then
  # Prepend $HOME/.local/bin: on a fresh Raspberry Pi shell it's not yet on
  # PATH, so without this dvw-install.sh's own `command -v devpod` probe
  # misses the arm64 binary step 1 just dropped there and sudo-installs its
  # hardcoded devpod-linux-amd64 to /usr/local/bin instead — permanently
  # shadowing the working arm64 copy.
  install_args=()
  if (( UNATTENDED )); then
    install_args=(--unattended --source "$MANAGED_SOURCE" --version "$MANAGED_VERSION")
  fi
  PATH="$HOME/.local/bin:$PATH:$HERE" dvw-install.sh "${install_args[@]}"
  ok "dvw client installed/refreshed"
  if (( UNATTENDED )); then
    "$AUTO_UPDATE" --ensure </dev/null
    ok "automatic update schedule enrolled"
  fi
fi

# 3. Push watcher: relay Termius paste-uploads into attached workspaces
# without the second tab (lib/push-watch.sh). Armed on connect once this
# flag is in the dvw config; `DVW_PUSH_WATCH=0` there turns it back off.
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"
watch_re='^[[:space:]]*DVW_PUSH_WATCH[[:space:]]*='
if grep -qsE "${watch_re}[[:space:]]*\"?1\"?[[:space:]]*(#.*)?$" "$DVW_CONFIG"; then
  ok "push watcher enabled in $DVW_CONFIG"
elif grep -qsE "$watch_re" "$DVW_CONFIG"; then
  # An explicit other value is the user's decision; re-running the installer
  # must not flip it back.
  ok "push watcher disabled by hand in $DVW_CONFIG (left alone)"
elif [[ "${DVW_BASTION_NO_WATCH:-}" == "1" ]]; then
  ok "push watcher skipped (DVW_BASTION_NO_WATCH=1)"
elif (( ! CHECK_ONLY )); then
  dvw_config_set DVW_PUSH_WATCH 1
  ok "push watcher enabled (DVW_PUSH_WATCH=1 in $DVW_CONFIG)"
else
  bad "push watcher not enabled (re-run without --check, or set DVW_PUSH_WATCH=1 in $DVW_CONFIG)"
fi

# 4. Reachability report
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
 - Paste an image in an attached session: it lands in the container's /tmp
   within ~2s (dvw watch status / dvw watch stop to inspect or disable).
 - Optional zero-keystroke attach: a SECOND keypair restricted in
   ~/.ssh/authorized_keys to:  command="dvw attach",no-port-forwarding,no-X11-forwarding <pubkey>
   and a second Termius host "jumpi ⏸" using that key.
EOF
exit "$fail"
