# `dvw push` — get a file into the workspace you're attached to

## Problem

Files on a dvw client machine have no direct path into a workspace container.
The gap hurts most from the phone: Termius's paste-images-and-files feature
(mobile 7.5.0+) uploads over SFTP to `/tmp` **on the SSH-connected host** —
which for the phone is jumpi — and auto-types the resulting path into the
terminal. But the terminal prompt is inside a workspace container two hops
away, so the typed path points at a file the shell can't see.

Desktop clients have the same gap in a different costume: over ssh + tmux,
native image paste into agent CLIs (Claude Code's Ctrl-V) doesn't survive the
hop, and a screenshot sitting on the Mint/WSL clipboard has no route into the
container either.

The dominant use case is handing a screenshot to a coding agent: the file
must land at a container path the user can reference in the agent prompt
within seconds.

## Spike evidence (2026-08-18, devMachine session)

- `scp /etc/hostname devmachine.devpod:/tmp/dvw-push-test` from jumpi worked
  first try, no fallback flags. devpod's injected sshd registers an `sftp`
  subsystem handler (`loft-sh/devpod` `pkg/ssh/server/ssh.go`,
  `sftp_handler.go`), so the existing `<ws>.devpod` aliases carry file
  transfer, not just terminals.
- A real phone paste arrived on jumpi as
  `/tmp/570d7e98-a20a-4e6a-ab30-c4b3400ae490.png` (699 KB) — Termius names
  uploads **bare UUIDv4 + original extension**. This is undocumented
  (docs/changelog/blog checked 2026-08-18: only "a unique filename"), so it
  is treated as a recognizer, never a load-bearing assumption.
- Relaying that file to the same path inside the container worked end to end
  (image verified readable in the container).
- Known footgun (wiki, verified against devpod v0.6.15): `devpod ssh --stdio`
  — the ProxyCommand behind every alias — **auto-ups a stopped workspace**
  with no opt-out. Any push must establish "running" from the catalog before
  touching an alias, same as the single-initiator connect flow (PR #34).

## Goal

One universal client-side primitive:

> **`dvw push` = put this file into the workspace this client is attached
> to, at a path I can paste into a coding session.**

It runs on any dvw client — jumpi, Mint, WSL — because they all have the
same dvw checkout and the same `<ws>.devpod` aliases. Termius's SFTP paste
is just the phone's way of getting a file onto a client; local files and the
clipboard are the desktop's.

### Primary flows

**Phone (two Termius tabs):**

1. Tab 1 is attached to a workspace via `dvw`/`dvw attach`. At the agent
   prompt, type `look at ` and paste the image. Termius uploads it to
   jumpi's `/tmp/<uuid>.png` and types that path into the prompt.
2. Tab 2 (plain jumpi prompt): `dvw push` — no arguments. It picks the fresh
   upload, pushes it to `/tmp/<uuid>.png` **in the attached container**, and
   prints that path.
3. Tab 1: hit enter. The path Termius already typed is now valid.

Because the destination mirrors the source basename under `/tmp`, no path
ever needs to be copied between tabs; the printed path is confirmation and
copyable fallback.

**Desktop:** `dvw push shot.png`, or `dvw push --clipboard` for a clipboard
image. The landed container path is printed and, where a clipboard tool
exists, placed on the local clipboard ready to paste into the agent session.

## Non-goals

- **No watcher/daemon** (deferred — see Future work).
- **No phone-side software** beyond Termius as-is.
- **No container-side component and no new credentials.** Containers gain no
  ssh identity; jumpi's trust posture is unchanged. Transfer rides the
  existing alias transport only.
- **No cleanup of source files.** Client `/tmp` clears on reboot; push never
  deletes or moves its input.
- **No push-into-repo.** Destination is container `/tmp` only; anything
  destined for the repo is the agent's or user's move afterwards.

## Design

### Command surface

```
dvw push                      # newest fresh Termius-style upload in /tmp
dvw push <file>...            # explicit local file(s)
dvw push --clipboard          # clipboard image (desktop clients)
dvw push ... --to <ws>        # explicit target, bypasses session detection
```

Implemented as `cmd_push` in a new `lib/push.sh`, dispatched like the other
subcommands, `--dry-run` honored (prints would-be `scp` invocations).

### Source selection

- **No args:** scan `${TMPDIR:-/tmp}` (maxdepth 1) for regular files that
  are (a) named `<uuidv4>.<ext>` — `[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}`
  plus a dot-extension, (b) owned by the invoking user, (c) modified within
  `DVW_PUSH_FRESH_MINUTES` (default 10), and (d) at most
  `DVW_PUSH_MAX_SIZE_MB` (default 50). Pick the **newest single match** and
  say so (`pushing 570d….png (uploaded 12s ago)`); other matches are
  reachable by explicit path. Zero matches → error explaining the filter and
  suggesting `dvw push <file>`.
- **Explicit files:** existence and the size cap are checked; the UUID and
  freshness filters do not apply.
- **`--clipboard`:** first available helper wins —
  `wl-paste --type image/png` (Wayland), `xclip -selection clipboard -t
  image/png -o` (X11), or on WSL `powershell.exe` `Get-Clipboard -Format
  Image` saved via `System.Drawing`. The image is written to a temp file
  named `clip-<HHMMSS>.png` (mirrors to a readable container path) and
  pushed. No image on the clipboard → clear error.

### Target resolution: the session registry

`_dvw_ssh_session` (`lib/connect.sh`) already creates a per-session marker
dir `${TMPDIR:-/tmp}/dvw-ssh.XXXXXX` whose lifecycle is managed by a RETURN
trap. It gains two files written at creation: `workspace` (the ws id) and
`pid` (the dvw client process). `_dvw_rm_marker_dir` already removes the
whole dir on session end; no new lifecycle code.

`dvw push` enumerates live sessions: every `dvw-ssh.*/workspace` whose `pid`
is still alive (`kill -0`). Dirs with a dead pid are ignored (SIGKILL can
orphan a marker; the next `_dvw_reap_stale_masters`-style sweep is not
needed — ignoring suffices).

- **Exactly one live session** → that workspace. The overwhelmingly common
  case, zero interaction.
- **Several** → numbered picker (same idiom as `dvw attach`'s multi-waiting
  picker); non-tty invocations error and demand `--to`.
- **None** → error: `not attached to any workspace from this machine — use
  dvw push --to <ws>`.

`--to <ws>` skips detection. Because the target was not proven alive by an
attached session, it is checked against the catalog first (same
catalog-before-alias ordering as the connect flow) and refused unless
running — never probe the alias to find out, that's the auto-up footgun.

### Transfer and destination

`_dvw_ensure_ssh_alias "$ws"` (as connect does), then
`scp -q <file> "<ws>.devpod:/tmp/"`. Destination is always
`/tmp/<basename>` in the container — the mirror that keeps Termius-typed
paths valid. An existing file of the same name is overwritten (same-name
means same-source re-push in practice; UUID names make cross-source
collisions negligible).

### Output

Per file: one status line during transfer, then the **container path as the
final line** of output, unadorned, so it is trivially copyable:

```
✓ 570d7e98-….png → devmachine (699 KB)
/tmp/570d7e98-a20a-4e6a-ab30-c4b3400ae490.png
```

On desktop clients, if a clipboard tool is present (`wl-copy`, `xclip`, or
WSL `clip.exe`), the path is additionally copied to the local clipboard and
the status line says so. Absence of a clipboard tool is silent — printing is
the contract, the clipboard is a bonus.

### Errors

Every failure names the failing hop: source selection (nothing fresh / file
missing / too big / no clipboard image), target resolution (no session,
ambiguous without tty, `--to` target not running per catalog), transfer
(scp exit status passed through with the alias name). Exit non-zero on any
failure; with multiple files, first failure aborts the rest (they share one
target; a broken transport fails them all identically).

## Testing

Bats (pure logic, no network):

- fresh-upload selection: UUID recognizer, owner/mtime/size filters, newest
  wins, zero-match error text
- session registry: one/several/zero live sessions, dead-pid markers
  ignored, `workspace`+`pid` written and cleaned by the existing trap path
- `--to` catalog gate: running → proceed, stopped/absent → refusal naming
  the state (catalog stubbed as in existing connect tests)
- dispatch and `--dry-run` printing

Manual smoke (documented in `tests/manual/`): the 2026-08-18 spike, i.e. a
real phone paste on jumpi relayed to a running workspace and read back.

## Docs

- README subcommand table: one row for `dvw push`.
- `docs/bastion.md`: a "Pasting files from your phone" section describing
  the two-tab flow verbatim (it is the feature's reason to exist).

## Future work (explicitly deferred)

**Opt-in watcher on jumpi** — the zero-command version: a systemd user unit
(off by default, enabled via install-bastion.sh flag) inotify-watching
`/tmp` with the same UUID/owner/freshness/size filters **plus** an
extension allowlist, armed only while at least one live session exists in
the registry, delivering to **all** live-session workspaces (no prompting —
a daemon has no UI; a ~1 MB stray in a container's ephemeral `/tmp` is the
accepted cost of never guessing wrong), confirming via
`ssh <ws>.devpod tmux display-message`. Build only if two-tab `dvw push`
proves annoying in practice. Its trigger heuristics degrade to "watcher
stops firing" if Termius changes naming — `dvw push` remains the fallback.

## Rejected alternatives

- **Container pulls from jumpi:** no route (names don't resolve from
  container network) and it would place a jumpi credential in agent-space —
  inverts the trust design that keeps containers credential-free.
- **Base64 through the terminal/tmux stream:** ~1 MB of pasted text per
  screenshot, tmux paste-buffer limits, no integrity check; the protocols
  that make this sane (zmodem, iTerm2 transfer) are unsupported by Termius.
- **Termius SFTP directly to the container:** structurally impossible — the
  container is only reachable through a `devpod ssh --stdio` ProxyCommand,
  which a phone app cannot execute.
- **Android share-target service (e.g. Termux + picker dialog):** the one
  option that can prompt for a target, but it adds a second keyed phone
  stack to maintain, duplicates what attached-session targeting gives for
  free, and still doesn't get the path into the agent prompt.
