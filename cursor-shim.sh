#!/usr/bin/env bash
# Self-healing Cursor shim for DevPod (and any CLI use of Cursor).
# Re-extracts the AppImage automatically when it gets updated.
set -e

APPIMAGE="$HOME/AppImages/cursor.appimage"
EXTRACTED="$HOME/AppImages/squashfs-root"
WRAPPER="$EXTRACTED/usr/share/cursor/bin/cursor"

if [[ ! -x "$WRAPPER" ]] || [[ "$APPIMAGE" -nt "$EXTRACTED" ]]; then
  cd "$HOME/AppImages"
  rm -rf squashfs-root
  ./cursor.appimage --appimage-extract >/dev/null
fi

exec "$WRAPPER" "$@"
