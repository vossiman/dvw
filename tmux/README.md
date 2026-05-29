# tmux — host-side configs and helpers

Counterpart to `aiCodingBaseSetup/configs/tmux/tmux.conf` (deployed automatically into every DevPod container by `install.sh`).

## Files

- **`tmux-local.conf`** — laptop/desktop config. Uses `Ctrl+a` prefix (same as container — we don't nest tmux).
- **`tmux-diag.sh`** — diagnostic script for clipboard/escape-sequence issues.
- **`clipboard-test.sh`** — dedicated clipboard-flow tester (OSC 52, xsel, xclip).
- **`ANALYSIS.md`** — investigation notes from when these were tuned.
- **`FIX.md`** — concrete fixes applied (escape-time tweaks, OSC 10/11 handling, etc.).

## Activation

### On a host (Mint laptop / desktop)

```bash
ln -sf ~/local_dev/dvw/tmux/tmux-local.conf ~/.tmux.conf
tmux kill-server   # if a session is running, restart to pick up the change
```

### In a fresh DevPod container

Nothing to do — `aiCodingBaseSetup/install.sh` runs as part of `postCreateCommand` and deploys `configs/tmux/tmux.conf` to `~/.tmux.conf` automatically.

### In an existing DevPod container (without recreating)

Pull the latest installer and re-run:

```bash
ssh -t <workspace>.devpod 'bash -lc "cd /tmp/aicoding && git pull origin main && bash install.sh"'
```

After it finishes, run `tmux kill-server` inside the container to restart any running sessions with the new config.

## Prefix

`Ctrl+a` everywhere — host and container. No tmux-in-tmux, so no collision.

| Where | Prefix | Config source |
|-------|--------|---------------|
| Host (Mint/Win11) | `Ctrl+a` | `tmux-local.conf` (this dir) |
| Container (DevPod workspace) | `Ctrl+a` | `aiCodingBaseSetup/configs/tmux/tmux.conf` |

Originated as a separate repo (`vossiman/tmuxing-archive` on GitHub holds the original commit `cfc787a` for reference).
