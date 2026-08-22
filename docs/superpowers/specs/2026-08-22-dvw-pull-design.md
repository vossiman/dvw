# dvw pull — design

**Date:** 2026-08-22
**Status:** approved (in-chat brainstorm, bounded path)

## Problem

Getting a file *out* of a devpod container currently means opening Cursor
(or hand-rolling an `scp` with the right alias and path). `dvw push` already
solves the inbound direction; there is no outbound mirror.

## Solution

`dvw pull` — an outbox convention plus a picker.

A project that wants to hand files back creates `out/` at the root of its
workspace checkout (`/workspaces/<ws>/out`). `dvw pull`, run on the client
machine, lists what is sitting there, lets you pick, and downloads into the
directory `dvw` was invoked from.

```
dvw pull [<file>...] [--from <ws>] [--all]
```

- `<file>...` — paths *relative to `out/`*; skips the picker.
- `--from <ws>` — explicit workspace instead of the attached one.
- `--all` — take everything in `out/`, no picker.
- `--` — option terminator, so dash-leading names work.

## Flow

1. **Resolve the workspace.** Reuses `dvw push`'s helpers unchanged:
   `_dvw_push_resolve_target` (live attached sessions on this machine; one
   wins outright, several go to a picker, none is an error) and
   `_dvw_push_require_running` (catalog must report RUNNING; fail closed on
   an unreachable catalog).
2. **Materialize local state.** `_dvw_ensure_local_devpod_state` then
   `_dvw_ensure_ssh_alias`, in that order — same as `cmd_push`. Both run
   *after* the RUNNING gate, because merely opening the alias auto-ups a
   stopped workspace (`devpod ssh --stdio`, no opt-out).
3. **List.** One `ssh <ws>.devpod` running
   `find /workspaces/<ws>/out -mindepth 1 -type f -printf '%s\t%P\0'`.
   Records are NUL-separated so newlines in names cannot desynchronize the
   parse. Remote exit 3 means the directory does not exist; empty output
   means it is empty; ssh's own 255 is reported as unreachable.
4. **Select.** `fzf --multi` when available, otherwise a numbered list
   accepting `1,3,5`, ranges (`2-4`), `all`, or empty to cancel.
5. **Transfer.** One `ssh <ws>.devpod "cat -- <path>"` per file, path quoted
   with `printf %q`. Bytes land in a sibling `.dvw-part` file and are `mv`d
   into place only after a clean exit.
6. **Land.** `$PWD/<relative path>`, subdirectories recreated with
   `mkdir -p`. Nothing is deleted in the container.

## Decisions

**`out/` is a copy source, not a queue.** Pull never deletes the remote
file. A failed local write can therefore never destroy the only copy, and
the same file can be pulled to two machines. Cleaning `out/` is the
project's job.

**Subpaths are preserved, not flattened.** `reports/q3.pdf` lands at
`./reports/q3.pdf`. Flattening to `q3.pdf` would let two files in different
subdirectories collide silently, turning a listing choice into data loss.

**Collisions are always a decision, never a default.** If the local path
exists, prompt `[o]verwrite / [r]ename / [s]kip / [c]ancel`. Rename asks for
a new name (offering `name-1.ext`) and re-checks that too, so answering
rename twice cannot clobber anything either. Cancel abandons the files not
yet transferred; already-transferred ones stay. Non-interactive stdin
without `DVW_ASSUME_TTY=1` is an error, not a silent overwrite.

**Path traversal is rejected, not sanitized.** A relative path that is
absolute, empty, or contains a `..` component is refused by name. `find
-printf '%P'` cannot produce one, so this only ever fires on a hand-typed
argument — but the check sits on the shared path so both routes are covered.

**The listing is sorted (`LC_ALL=C`).** `find` returns directory order,
which is arbitrary and can differ between two runs over an unchanged outbox —
so a remembered index would silently select a different file. Byte order, not
locale order, so the numbering doesn't move between machines either.

**`ssh cat`, not `scp`.** `scp` has two incompatible behaviours for the
remote path depending on the OpenSSH version: before 9.0 the remote shell
re-parses it, so a name with a space needs shell quoting; from 9.0 the path
travels over SFTP verbatim, so that same quoting becomes part of the name. No
single spelling is right for both, and this client talks to whatever sshd
devpod injected. `ssh cat` has exactly one parser — the remote shell — and we
quote for it. (`dvw push` keeps `scp`; its remote destination is a fixed
`/tmp/`, so it never hits this.)

**A transfer is committed, not streamed into place.** The download writes
`<dest>.dvw-part` and renames it (same directory, so atomic) only on a clean
exit. An interrupted pull therefore leaves neither a truncated file under the
real name nor a destroyed copy of the file the user chose to overwrite.

**Size cap mirrors push.** `DVW_PULL_MAX_SIZE_MB`, default 50, enforced
from the size `find` already reported, before any transfer starts.

**Names containing a tab or newline are listed but not pickable.** Both
pickers are line- and field-oriented. Rather than silently mangle such a
name, the picker drops it with a warning naming the count; it remains
pullable by explicit argument.

## Not included

- Creating `out/` for you, or gitignoring it — a project decides whether its
  outbox is tracked.
- A TUI screen.
- Watching `out/` for new files.

## Tests

`tests/bats/pull-cmd.bats` (argv contract, gates, transfer shape, dry-run) and
`tests/bats/pull-pick.bats` (listing parse, selection grammar, collision
resolution, path safety), following the `push-*.bats` idiom: `ssh`
stubbed on a sanitized PATH (dispatching on the remote command — `find` is a
listing, `cat` a transfer), resolution and alias registration stubbed at the
function boundary.
