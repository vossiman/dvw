# Clipboard bridge — native image paste into agent CLIs over ssh+tmux

Status: approved in-conversation 2026-08-27 (devMachine session).
Requirement & research: `devMachine:docs/notes/2026-08-25-native-image-paste-requirement.md`.

## Problem

Claude Code's Ctrl+V image paste execs `xclip`/`wl-paste` on the machine it
runs on — inside a devpod container that queries a clipboard that doesn't
exist. Terminal-escape routes (OSC 52/5522) die at tmux, and upstream
declined native support (anthropics/claude-code#42712). `dvw push
--clipboard` works but is a manual side-channel.

## Decision (user, 2026-08-27)

Approach A — reverse-tunnel clipboard bridge:

- **Images only.** The bridge never serves text — clipboards hold
  passwords; any container process can query the socket silently.
  Enforced client-side (the trust boundary), not in the shim.
- **dvw-launched** client server (no systemd, no per-connection hacks).
- **Linux + WSL together**; Claude Code first (Codex's X11 path deferred).

Spike results (2026-08-27, recorded in the requirement note): devpod
v0.6.15's injected sshd supports `streamlocal-forward@openssh.com`,
allows reverse forwards unconditionally, and unlinks stale sockets
before bind. Live test through the `devpod ssh --stdio` hop from Surface
WSL: PASS, ~23-42 ms round trip.

## Architecture

```
[client: Mint/WSL]                      [container]
 dvw-clipd ── ~/.dvw/clip.sock          /tmp/dvw-clip.sock ◄─ RemoteForward
   │ (wl-paste / xclip / powershell)         │
   └── ensured by dvw connect/attach         └── xclip/wl-paste shims (aicoding)
                                                  ▲ exec'd by Claude Code Ctrl+V
```

Paste flow: Ctrl+V → Claude Code execs shim → shim reads container
socket → ssh reverse forward carries it to dvw-clipd → clipd grabs the
image from the real clipboard → bytes stream back. ~25 ms overhead.

## Components

### 1. dvw-clipd (dvw: `lib/clipd.sh` + `clipd/dvw-clipd.py`)

Python 3 stdlib HTTP server on a client-local unix socket
`~/.dvw/clip.sock` (0700 dir, 0600 socket).

Endpoints:
- `GET /targets` → `text/plain`, one MIME per line, the clipboard's
  current formats filtered to `image/*`; empty body when none.
- `GET /clip?type=image/png` → `200` + raw bytes, or `404` when the
  clipboard holds no image of that type.
- anything else → `403`. Non-`image/*` `type` → `403`. This is the
  images-only enforcement point.

Grab backends, chosen by environment (not first-installed):
1. WSL (detected first, via the `wsl_bridge_is_wsl()` logic): 
   `powershell.exe -NoProfile`, trying the alpha-preserving `"PNG"`
   clipboard format, falling back to
   `[System.Windows.Forms.Clipboard]::GetImage()` → PNG. Must be
   `powershell.exe` (5.1), never `pwsh` (7.x is text-only).
2. Wayland (`WAYLAND_DISPLAY`): `wl-paste -l` / `wl-paste --type <mime>`.
3. X11: `xclip -selection clipboard -t TARGETS -o` / `-t <mime> -o`.

Lifecycle: `dvw clipd ensure|status|stop`. `ensure` is idempotent
(pidfile `~/.dvw/clipd.pid`, stale-pid safe) and is called from the
connect/attach path before ssh. No idle timeout in v1.

`_dvw_push_clipboard_grab` (lib/push.sh) is refactored to share the
same backend-selection order (WSL first — fixes the WSLg `wl-paste`
`image/bmp`-only trap where the grab failed without falling through).

### 2. SSH blueprint managed block v3 (dvw: catalog-service)

`blueprint_store.py`: `MANAGED_VERSION = 3`, adding after the
`Host *.devpod` stanza:

```
Match host "*.devpod" exec "test -S %d/.dvw/clip.sock"
  RemoteForward /tmp/dvw-clip.sock %d/.dvw/clip.sock
```

(`%d` = local user's home; both `Match exec` and `RemoteForward` accept
tokens — validated against real OpenSSH with `ssh -G`: the forward
appears only when the socket exists, and only for `*.devpod`.) v2 kept
in `_MANAGED_BLOCKS` for migration, per the existing pattern.

The `Match exec` guard is load-bearing, not cosmetic: devpod's sshd
unlinks the previous container socket on every new bind (last-writer-
wins). An unconditional forward would let a clipd-less client — jumpi,
i.e. every phone attach — bind the container socket and steal the
bridge from a desktop client that can actually serve images. With the
guard, only clients with a live clipd request the forward; among those,
the newest wins (pastes reach the most recently connected machine,
matching intuition).

### 3. Container shims (aicoding blueprint)

Fake `xclip` and `wl-paste` installed into the container's
`~/.local/bin` (ahead of system PATH; real tools are not installed in
containers). Pure translators to `curl --unix-socket /tmp/dvw-clip.sock
--max-time 3`:

- `xclip -selection clipboard -t TARGETS -o` → `GET /targets`
- `xclip -selection clipboard -t <mime> -o` → `GET /clip?type=<mime>`
- `wl-paste -l` / `--list-types` → `GET /targets`
- `wl-paste --type <mime>` / `-t <mime>` → `GET /clip?type=<mime>`
- socket absent/dead, HTTP non-200, or any unrecognized invocation →
  exit 1 with a "no image" stderr line (Claude Code then shows its
  normal "No image found in clipboard").

No caching, no temp files, no writes.

## Failure modes

- clipd not running / client disconnected → shim exits non-zero fast
  (`--max-time 3`); nothing hangs.
- Two clients attached → newest connection owns the socket (sshd
  unlink-on-bind, verified in source and spike).
- Termius/jumpi: no clipd on jumpi by default → no forward content;
  phone flow stays `dvw push` (unchanged).
- Malicious container process → can only ever obtain image/* data;
  text is refused at the client boundary.

## Testing

- dvw bats: clipd ensure/status/stop (pidfile semantics, stale pid),
  images-only refusal (`/clip?type=text/plain` → 403), grab-backend
  selection with mocked tools + mocked WSL detection, push.sh
  refactor regression (existing push bats keep passing).
- catalog-service pytest: v2→v3 migration (managed block replaced,
  custom content preserved), byte-for-byte v2 recognition, new-install
  document contains the RemoteForward line.
- aicoding bats: shim translation matrix (mocked curl), dead-socket
  behavior, unrecognized-flag behavior.
- Manual acceptance: Ctrl+V into Claude Code in this container from
  Surface WSL (and later from Mint kitty).

## Non-goals (v1)

- Codex/Cursor native paste (needs X11 bridge — follow-up).
- Text clipboard in either direction.
- clipd on jumpi / any phone-side change.
- Auto-push watcher (separate dvw-push follow-up).
