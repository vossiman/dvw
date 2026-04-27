# tmux — host-side configs and helpers

Counterpart to `aiCodingBaseSetup/configs/tmux/tmux.conf` (deployed automatically into every DevPod container by `install.sh`).

## Files

- **`tmux-local.conf`** — laptop/desktop config. Uses `Ctrl+a` prefix so it doesn't collide with the container's `Ctrl+b` when nesting tmux sessions.
- **`tmux-diag.sh`** — diagnostic script for clipboard/escape-sequence issues.
- **`clipboard-test.sh`** — dedicated clipboard-flow tester (OSC 52, xsel, xclip).
- **`ANALYSIS.md`** — investigation notes from when these were tuned.
- **`FIX.md`** — concrete fixes applied (escape-time tweaks, OSC 10/11 handling, etc.).

## Install on a host

```bash
ln -sf ~/local_dev/devMachine/devpod/tmux/tmux-local.conf ~/.tmux.conf
tmux kill-server   # if a session is running, restart to pick up the change
```

## Why local + remote differ

Two coexisting tmux instances need different prefixes, otherwise the inner instance never sees the prefix because the outer captures it. Convention here:

| Where | Prefix | Config source |
|-------|--------|---------------|
| Host (Mint/Win11) | `Ctrl+a` | `tmux-local.conf` (this dir) |
| Container (DevPod workspace) | `Ctrl+b` | `aiCodingBaseSetup/configs/tmux/tmux.conf` |

Originated as a separate repo (`vossiman/tmuxing-archive` on GitHub holds the original commit `cfc787a` for reference).
