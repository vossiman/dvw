# devpod — host-side helpers

Scripts that fix host-machine integration issues when using DevPod with Cursor on Linux.

## cursor-shim.sh

Wrapper that lets DevPod launch Cursor without spawning multiple windows per `devpod up`.

**Why it exists:** DevPod calls `cursor` three times when opening a workspace — `--list-extensions`, `--install-extension`, `--new-window`. The first two are meant to be silent CLI calls; the third opens the window. The raw Cursor AppImage entrypoint always opens a GUI window regardless of arguments, so without this shim you get three Cursor windows on every `devpod up`.

The shim points DevPod at Cursor's internal CLI wrapper (`squashfs-root/usr/share/cursor/bin/cursor`), which correctly dispatches CLI flags vs. window-open. It also auto-re-extracts the AppImage when it's been updated, so daily Cursor updates don't break anything.

## Install

```bash
./devpod/install-cursor-shim.sh
```

Prerequisites:
- Cursor AppImage at `~/AppImages/cursor.appimage`
- `~/.local/bin` on `PATH` (the installer warns if it isn't)

## Update flow

Cursor updates itself in place by overwriting `~/AppImages/cursor.appimage`. The shim detects the new mtime on the next invocation and re-extracts automatically — no manual step needed.
