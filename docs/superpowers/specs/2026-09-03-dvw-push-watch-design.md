# `dvw watch` — bastion push watcher

Ticket: DEVMACHINE-3. Builds the "opt-in watcher on jumpi" deferred in
`2026-08-18-dvw-push-design.md` § Future work, after the two-tab `dvw push`
flow proved annoying in practice (2026-09-03: a phone paste arrived in a
Claude session as `/tmp/<uuid>.png`, the container had no such file, and the
agent asked for a re-paste).

## Problem

Termius mobile uploads a pasted image over SFTP to `/tmp` on jumpi and types
that path into the terminal. The prompt is in a workspace container, so the
path is dangling until `dvw push` runs in a second tab. The user wants:
paste, pause, enter, one tab.

## Design

A poll loop on the client that does, unattended, exactly what `dvw push`
does by hand:

- **Same recognizer, same roots.** `_dvw_push_list_fresh` (factored out of
  the picker in `lib/push.sh`) lists fresh `<uuidv4>.<ext>` files owned by
  the user under `${TMPDIR:-/tmp}` and `/tmp`, size-capped, newest first.
- **Extension allowlist** (`DVW_PUSH_WATCH_EXTS`, default images plus pdf,
  txt, md). The watcher delivers without asking, so it only touches what a
  phone paste produces. `dvw push <file>` remains the route for the rest.
- **Upload-in-progress guard.** A file is delivered only once its size is
  unchanged between two consecutive polls, so an SFTP upload still streaming
  in is never copied half-written. Costs one extra poll interval (1 s).
- **Fan-out to every live session.** Targets are `_dvw_push_live_sessions`,
  the same registry `dvw push` uses. No prompting: a daemon has no UI, and a
  stray file in an unused container's ephemeral `/tmp` is the accepted cost
  of never guessing wrong. Each target passes the RUNNING gate before the
  alias is touched (never boot a stopped workspace), and one failing target
  never blocks the others.
- **Confirmation in the session**, best effort: `ssh <ws>.devpod tmux
  display-message "dvw: /tmp/<name> ready"`.
- **Startup skip.** Files already present when the loop starts are marked
  done; re-sending the last ten minutes on every start would be a surprise.
- **Lifecycle mirrors clipd.** `_dvw_ssh_session` (the connect path) calls
  `_dvw_push_watch_ensure_quiet`, which is a no-op unless `DVW_PUSH_WATCH=1`
  and otherwise starts `dvw watch run` detached with a pidfile under
  `~/.dvw`. The loop exits by itself after `DVW_PUSH_WATCH_IDLE_EXIT`
  (120 s) with no live session, so it is armed exactly while sessions exist.
  A restart after `dvw update` picks up new code because each start is a
  fresh `dvw watch run` process.
- **Opt-in via config.** `install-bastion.sh` writes `DVW_PUSH_WATCH=1` to
  the dvw config file (`lib/config.sh` now recognizes the key); desktops
  never get it. `DVW_PUSH_WATCH=0` in the file, or `DVW_BASTION_NO_WATCH=1`
  at install time, turns it off. `dvw watch status|start|stop|run`.

## Deviations from the deferred sketch

- **Polling, not inotify.** One `find` per second on two directories is
  free on a Pi and needs no `inotify-tools`; latency is at most two poll
  intervals. `DVW_PUSH_WATCH_INTERVAL` tunes it.
- **No systemd unit.** Connect-path arming plus idle exit gives "armed only
  while at least one live session exists" without a unit file, user
  lingering, or a second install step. The tradeoff: a session opened by a
  path other than `_dvw_ssh_session` (none today) would not arm it.

## Verification

- `tests/bats/push-watch.bats`: tick semantics (stable-size delivery, once;
  growing file waits; fan-out; RUNNING gate; allowlist; non-Termius names;
  per-target failure isolation; tmux confirmation), the foreground loop
  (startup skip, later upload delivered, idle exit), ensure/status/stop
  lifecycle, the `DVW_PUSH_WATCH` gate, config-file round trip.
- Field test: on jumpi, `dvw update`, `bash install-bastion.sh`, attach
  from Termius, paste an image, wait ~2 s, enter. `dvw watch status` and
  `~/.dvw/push-watch.log` show what happened.
