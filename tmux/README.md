# tmux — host-side configs and helpers

Counterpart to `aiCodingBaseSetup/configs/tmux/tmux.conf` (deployed automatically into every DevPod container by `install.sh`).

## Files

- **`tmux-local.conf`** — laptop/desktop config. Uses `Ctrl+a` prefix (same as container — we don't nest tmux).
- **`tmux-diag.sh`** — diagnostic script for clipboard/escape-sequence issues.
- **`clipboard-test.sh`** — dedicated clipboard-flow tester (OSC 52, xsel, xclip).
- **`codex-scroll-test.sh`** — repeatable Codex/tmux rendering test. Prompts for a free-text environment label, runs a fixed 180-line Codex response, records whether scrolling repaired the display, and appends diagnostics plus tmux's internal capture to a log.

Run the scroll test from each environment you want to compare:

```bash
bash devpod/dvw/tmux/codex-scroll-test.sh
```

Results default to `~/.local/state/codex-scroll-test/results.log`. To collect
multiple machines into a shared or repository-external file, pass
`--log /path/to/results.log` or set `CODEX_SCROLL_TEST_LOG`. Use
`--collect-only` to record an already-observed session without launching Codex.

Clipboard / DA1 investigation notes were archived into `KNOWN_ISSUES.md`
(“Archived — host tmux clipboard / DA1”).

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
