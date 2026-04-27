#!/usr/bin/env bash
# Installs the Cursor shim to ~/.local/bin/cursor so DevPod can launch
# Cursor without spawning multiple windows on each `devpod up`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SOURCE="$SCRIPT_DIR/cursor-shim.sh"
SHIM_TARGET="$HOME/.local/bin/cursor"
APPIMAGE="$HOME/AppImages/cursor.appimage"

[[ -f "$SHIM_SOURCE" ]] || { echo "ERROR: cursor-shim.sh not found next to this script"; exit 1; }
[[ -f "$APPIMAGE" ]]    || { echo "ERROR: $APPIMAGE not found — install Cursor AppImage there first"; exit 1; }

mkdir -p "$HOME/.local/bin"
install -m 0755 "$SHIM_SOURCE" "$SHIM_TARGET"
echo "Installed shim: $SHIM_TARGET"

# Trigger a first extraction so the next `cursor` call is fast.
chmod +x "$APPIMAGE"
cd "$HOME/AppImages"
if [[ ! -d squashfs-root ]] || [[ "$APPIMAGE" -nt squashfs-root ]]; then
  rm -rf squashfs-root
  ./cursor.appimage --appimage-extract >/dev/null
  echo "Extracted AppImage to $HOME/AppImages/squashfs-root"
fi

# PATH sanity check.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARN: $HOME/.local/bin is not on PATH — add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your shell rc" ;;
esac

# Smoke test.
if "$SHIM_TARGET" --version >/dev/null 2>&1; then
  echo "OK: cursor --version succeeded"
else
  echo "ERROR: cursor --version failed — check $SHIM_TARGET and the wrapper path inside it"
  exit 1
fi
