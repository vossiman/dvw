# Paseo pairing: auto-heal the SSH alias on a fresh machine

**Date:** 2026-06-18
**Status:** Approved (design)

## Problem

The catalog service lists *every* workspace on every machine. So the dvw TUI on
a second machine (e.g. a desktop) shows pods that have never been connected to
*from that machine* — including their **Pair remote (paseo)** action.

Paseo pairing fails for those pods. `pair_paseo` (`tui/dvw_tui/actions.py`) is the
**only** TUI action that bypasses bash and ssh's directly:

```python
return ["ssh", f"{workspace_id}.devpod", "~/.local/bin/aicoding-paseo-daemon pair"]
```

DevPod writes the per-workspace `Host <id>.devpod` alias only on the machine that
ran `devpod up`/`devpod ssh`. On a fresh machine that alias is absent, so the ssh
fails with a cryptic `Could not resolve hostname <id>.devpod`. Today that surfaces
in `PairScreen` only as a generic catch-all hint, indistinguishable from "pod is
down" or "daemon not installed".

This also violates the stated principle in `actions.py`: *"the TUI never
orchestrates devpod itself — every action shells out to the battle-tested bash
`dvw` paths."* Every other action (`stop`/`start`/`rebuild`/`remove`/`connect`)
goes through `dvw <subcommand>`; pairing is the lone raw-ssh leak.

## Decision

**Auto-heal.** Route pairing through a new bash `dvw pair <id>` subcommand that
runs the same two idempotent, container-safe helpers `cmd_connect` already runs,
then performs the paseo pairing ssh.

Rationale (why auto-heal over detect-and-advise):
- The helpers are **already battle-tested**. `_dvw_ensure_ssh_alias` runs
  unconditionally in `cmd_connect` (`lib/connect.sh:42`) and again as a fallback
  in `_connect_ssh` (`:104`) — i.e. on every connect from a fresh machine. We are
  adding a *caller*, not a second implementation.
- The "two writers of `~/.ssh/config`" concern (dvw vs devpod) is **already the
  status quo** and already handled: the block uses devpod's identical
  `# DevPod Start/End <id>.devpod` markers and mirrors devpod's field order, so a
  later real `devpod up` reasserts identical content in place rather than
  duplicating it. Idempotent via `_dvw_ssh_alias_present`.
- It makes pairing consistent with connect and removes the raw-ssh leak.

## Why both helpers (not just the alias writer)

The alias block's `ProxyCommand` is
`devpod ssh --stdio --context <ctx> --user <user> <id>`. That fails unless devpod
also has local workspace state (`~/.devpod/.../workspaces/<id>/workspace.json`).
So `cmd_pair` must run both, in the same order as `cmd_connect`:

1. `_dvw_ensure_local_devpod_state "$id"` — materialize `workspace.json` from the
   catalog snapshot if absent. Returns 1 (with a helpful message) for legacy
   catalog entries that have no snapshot — `cmd_pair` then stops without
   attempting the ssh.
2. `_dvw_ensure_ssh_alias "$id"` — append the `Host <id>.devpod` block if absent.

Neither helper starts a container or runs `devpod up`. Scope is strictly "make
`<id>.devpod` resolvable on this machine". If the pod is *stopped*, the paseo ssh
still fails and the existing `PairScreen` hint applies — starting the pod remains
Connect's job, out of scope here.

## Implementation

### bash — `lib/connect.sh`

Add `cmd_pair` next to `cmd_connect` (it depends on connect.sh helpers):

```bash
cmd_pair() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    ui_error "usage: dvw pair <workspace-id>"
    return 1
  fi
  _dvw_ensure_local_devpod_state "$id" || return 1
  _dvw_ensure_ssh_alias "$id"          || return 1
  exec ssh "${id}.devpod" "~/.local/bin/aicoding-paseo-daemon pair"
}
```

(Exact pairing command string mirrors today's `pair_paseo`.)

### bash — `dvw` (dispatch)

Add a `pair)` case in `main()`'s `case` block:

```bash
    pair)
      shift; cmd_pair "$@" ;;
```

### Output cleanliness

`main()` runs catalog/blueprint/wsl sync with `ui_progress` before dispatch; those
print subtle progress lines to **stderr** only if the step exceeds 0.8s.
`run_captured` (the TUI) merges stdout+stderr. Keep the QR screen clean by
ensuring `cmd_pair`'s only stdout additions are the (no-op on happy path) ensure
messages; if the sync preamble proves visibly noisy in the pair screen during
implementation, suppress it for the `pair` path (e.g. route the preamble progress
to a sink, or skip the non-essential syncs for `pair`). Decide with the real
rendered output, not speculatively.

### TUI — `tui/dvw_tui/actions.py`

```python
def pair_paseo(workspace_id: str) -> list[str]:
    return [dvw_bin(), "pair", workspace_id]
```

`PairScreen` is unchanged: it still `run_captured`s the argv, renders ANSI, and
shows the existing hint on `rc != 0` (now a genuine fallback for non-alias
failures like a stopped pod).

## Testing

- **TUI** (`tui/tests/test_actions.py`): update `test_pair_paseo_builds_ssh_argv`
  → expect `[dvw, "pair", "alpha"]` (rename accordingly). Existing
  `test_pair_screen.py` keeps passing (mocks `run_captured`).
- **bash** (`tests/bats`): add `cmd_pair` coverage —
  - missing id → usage error, rc 1, no ssh.
  - happy path: both ensures invoked, then the paseo ssh command. Mock
    `_dvw_ensure_local_devpod_state`, `_dvw_ensure_ssh_alias`, and `ssh`/`exec`
    to assert ordering and that ssh is reached only after both ensures succeed.
  - `_dvw_ensure_local_devpod_state` fails (no snapshot) → rc 1, ssh **not**
    reached.

## Non-goals

- Starting a stopped pod (Connect's job).
- Touching the catalog-snapshot / uid-reconciliation / canonical-container
  machinery — reused as-is, unchanged.
- A `dvw pair` chooser or flags; it's a single fixed action.
