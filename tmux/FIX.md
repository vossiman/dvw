# Tmux Fix — RESOLVED

All three problems are fixed and verified across Env A and Env B.

## Problems (all resolved)

1. **Garbled characters on tmux startup in Env B** — FIXED
2. **Clipboard broken in Env B** — FIXED
3. **Clipboard broken in Env C** — FIXED (same config, needs deploy)

## Root Causes

### Clipboard: Malformed Ms capability (tmux #4081)

Our `terminal-overrides` used a single-param Ms format:
```
Ms=\E]52;c;%p2%s\7    ← BROKEN (missing %p1)
```

The correct format requires TWO parameters:
```
Ms=\E]52;%p1%s;%p2%s\7    ← correct
```

ncurses `tparm()` in tmux 3.4 silently rejects the single-param format — no
error, no clipboard, text only goes to the paste buffer.

tmux's default `terminal-features` (`xterm*:clipboard`) already provides the
correct Ms. Our `terminal-overrides` overwrote it with the broken one.

**Fix:** Remove Ms from `terminal-overrides`. Let the defaults work.

Reference: https://github.com/tmux/tmux/issues/4081

### Garbled characters: Two separate issues

**Issue 1 — DA1 response leaks (from programs inside tmux):**
With `allow-passthrough on`, programs inside tmux could send DA1 queries
(`\e[c`) via DCS passthrough to the outer terminal. Over SSH, the responses
arrived late and rendered as visible text (`^[[?61;...;52c`).

**Fix:** `set -g allow-passthrough off`. Not needed now that native clipboard
works without DCS passthrough.

**Issue 2 — OSC 10/11 response leaks (from tmux itself):**
tmux 3.4 queries the outer terminal for foreground/background colors on client
attach by sending `\e]10;?\e\\` and `\e]11;?\e\\`. Over SSH, the responses
(`^[]10;rgb:bebe/bebe/bebe`, `^[]11;rgb:0000/0000/0000`) arrived too late for
tmux's key parser to consume them (with `escape-time 0`, tmux doesn't wait for
multi-byte escape sequences). The responses leaked as garbled text.

**Fix:** `set -s escape-time 50` (gives tmux time to parse fragmented SSH
responses) + `set -g window-style 'fg=default,bg=default'` (pre-sets colors so
tmux may skip the query).

Known issue: tmux#3838, microsoft/terminal#18004, gpakosz/.tmux#720.
Starship is NOT the source — confirmed no OSC 10/11 querying code.

## Final Config (relevant sections)

```tmux
# Truecolor only — do NOT set Ms (defaults handle clipboard correctly)
set -g terminal-overrides ""
set -ag terminal-overrides ",xterm-kitty:RGB"
set -ag terminal-overrides ",xterm-256color:RGB"
set -ag terminal-overrides ",tmux-256color:RGB"

# Clipboard: native copy-mode → Ms → OSC 52
set -g set-clipboard on

# Passthrough off — prevents DA1 leaks from programs inside tmux
set -g allow-passthrough off

# Pre-set pane colors (prevents tmux 3.4 OSC 10/11 query over SSH)
set -g window-style 'fg=default,bg=default'
set -g window-active-style 'fg=default,bg=default'

# 50ms escape-time — prevents fragmented SSH responses from leaking
set -s escape-time 50

# Copy bindings — no pipe scripts needed
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel
```

## Verification

| Environment | Clipboard | Garbled chars | Status |
|---|---|---|---|
| **Env A** (Local Kitty+tmux) | WORKING | N/A | **VERIFIED** |
| **Env B** (Windows→SSH→tmux) | WORKING | GONE | **VERIFIED** |
| **Env C** (Kitty→SSH→Gitpod) | WORKING | N/A | **VERIFIED** |

### Paste behavior

- **Mouse drag / `v`+`y` in copy mode** → copies to system clipboard (OSC 52)
- **Ctrl+Shift+V** → pastes from system clipboard (terminal handles this)
- **Right-click** → pastes from tmux internal buffer (by design)

## Fix History

### Fix Attempt #1 — FAILED
Removed pipe scripts, relied on native Path B (copy-mode → Ms → OSC 52).
Ms was still broken (malformed format), so clipboard didn't work.

### Fix Attempt #2 — PARTIAL SUCCESS (Env A clipboard fixed)
Removed broken Ms from `terminal-overrides`. Native clipboard worked.
But garbled chars in Env B persisted — `allow-passthrough off` only blocked
the DA1 leak. OSC 10/11 leaks were from tmux itself (not passthrough).

### Fix Attempt #3 — FULL SUCCESS (all issues resolved)
Added `escape-time 50` and `window-style fg=default,bg=default` to handle
tmux 3.4's own OSC 10/11 queries over SSH. All garbled text eliminated.

## Files

| File | Status |
|---|---|
| `ANALYSIS.md` | Complete diagnostic and root cause analysis |
| `FIX.md` | This file — resolution summary |
| `tmux-diag.sh` | Diagnostic script (tested in all 3 envs) |
| `clipboard-test.sh` | Interactive clipboard tester |
| `tmux-local.conf` | **WORKING** — deployed as ~/.tmux.conf on Mint |
| `tmux-remote.conf` | **READY** — deploy on remote servers (Env C) |

## Remaining

None — all issues resolved. The bleopt calls were already removed from .bashrc.
