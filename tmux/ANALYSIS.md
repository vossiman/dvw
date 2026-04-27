# Tmux Terminal Diagnostics — Problem Map

## Environment Matrix

Three environments where tmux clipboard and escape sequence handling differs.

### Environment A: Local (Working)

```
┌─────────────────────────────────────────────────────┐
│  Kitty (xterm-kitty, truecolor)                     │
│  ├─ TERM=xterm-kitty                                │
│  ├─ Supports: OSC 52, OSC 10/11, RGB, DCS          │
│  │                                                   │
│  └─► tmux 3.4 (default-terminal: tmux-256color)     │
│      ├─ set-clipboard on                             │
│      ├─ allow-passthrough off                        │
│      ├─ terminal-features: xterm*:clipboard (default)│
│      ├─ terminal-overrides: RGB only (no Ms)         │
│      │                                               │
│      └─► bash 5.2 + ble.sh 0.4.0-devel + starship   │
│          └─ Copy: native (copy-selection-and-cancel)  │
└─────────────────────────────────────────────────────┘
```

**Status:** FIXED (2026-02-19). Native clipboard works — no scripts needed.

**Diagnostic results (2026-02-19):**

Outside tmux (Kitty direct):
```
TERM=xterm-kitty, COLORTERM=truecolor, X11 (:0)
OSC 52 write+read:  PASS (full round-trip)
OSC 10:             PASS (rgb:d4d4/dada/f6f6)
OSC 11:             PASS (rgb:1818/1818/2525)
```

Inside tmux:
```
TERM=tmux-256color, TERM_PROGRAM=tmux 3.4
OSC 52 write:       PASS (verified via read-back)
DCS passthrough:    PARTIAL (response received, content mismatch)
DCS probe:          WARN (no response from outer terminal via DCS)
OSC 10:             PASS (response received through tmux)
OSC 11:             PASS (response received through tmux)
set-clipboard:      on
allow-passthrough:  on
Ms capability:      set for xterm-kitty, xterm-256color, tmux-256color
escape-time:        0ms
tmux-yank.sh:       found at ~/.local/bin/tmux-yank.sh
```

**Key finding (CORRECTED):** The diag's OSC 52 "PASS" tested the APPLICATION
→ tmux path (printf sends `\e]52;c;...\a` to tmux PTY, tmux intercepts via
`set-clipboard on` and forwards to outer terminal). This is a DIFFERENT code
path from copy-mode → Ms → OSC 52. We initially assumed they were the same
and that tmux-yank.sh was redundant. **This was wrong.**

When we deployed a config without tmux-yank.sh (relying on native copy-mode
→ Ms), clipboard broke on local Env A. See "Fix Attempt #1" section below.

**Also noted:** `SSH_TTY` environment variable persists inside tmux even for
locally-launched sessions (not in tmux's `update-environment` list). This is
a false positive — not actually over SSH.

### Environment B: Windows → SSH → Mint tmux (Broken)

```
┌──────────────────────────────────────────────────────────┐
│  Windows Terminal                                         │
│  └─► WSL Ubuntu                                          │
│      └─► SSH (alias forces TERM=xterm-256color)          │
│          │                                                │
│          ▼                                                │
│  ┌───────────────────────────────────────────────────┐   │
│  │  Mint Linux                                        │   │
│  │  └─► tmux 3.4 (same config as Env A)              │   │
│  │      ├─ set-clipboard on                           │   │
│  │      ├─ allow-passthrough on                       │   │
│  │      │                                              │   │
│  │      └─► bash + ble.sh + starship                  │   │
│  │          └─ Copy: tmux-yank.sh (DCS passthrough)   │   │
│  └───────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

**Symptoms:**
- Garbled OSC characters appear when opening tmux
- Clipboard completely breaks inside tmux (works outside tmux over SSH)

**Diagnostic results (2026-02-19):**

Outside tmux (SSH into Mint, no tmux):
```
TERM=xterm-256color, COLORTERM=<unset>, Display=<none>
OSC 52 write:       WARN (sent, cannot verify — no read-back)
OSC 52 read:        FAIL (no response — Win Terminal doesn't support read-back)
OSC 10:             PASS (rgb:bebe/bebe/bebe — WSL gray)
OSC 11:             PASS (rgb:0000/0000/0000 — WSL black)
ble.sh:             NO
```

Inside tmux (SSH+TMUX):
```
TERM=tmux-256color, TERM_PROGRAM=tmux 3.4
Over SSH:           YES (10.0.0.193→10.0.0.148)
OSC 52 write:       PASS (verified via read-back!)
DCS passthrough:    PARTIAL (content mismatch)
OSC 10:             WARN (no response inside tmux)
OSC 11:             WARN (no response inside tmux)
DCS probe:          WARN (no response)
set-clipboard:      on
allow-passthrough:  on
Ms capability:      set (all 3 overrides)
escape-time:        0ms
tmux-yank.sh:       found
ble.sh:             NO
```

**GARBLED CHARACTERS — CAPTURED:**
The exact garbage visible on tmux startup:
```
^[[?61;4;6;7;14;21;22;23;24;28;32;42;52c^[]10;rgb:bebe/bebe/bebe^[\^[]11;rgb:0000/0000/0000^[\
```
This is three leaked escape sequence responses from Windows Terminal:
1. `^[[?61;...;52c` — **DA1 (Device Attributes) response** — something sent `\e[c`
   to query terminal type; Windows Terminal responded and the response leaked
2. `^[]10;rgb:bebe/bebe/bebe` — **OSC 10 response** (foreground color: gray)
3. `^[]11;rgb:0000/0000/0000` — **OSC 11 response** (background color: black)

Additional leaked text appeared at the prompt (highlighted red):
```
10;rgb:bebe/bebe/bebe11;rgb:0000/0000/0000
```

**Root cause confirmed:** With `allow-passthrough on`, startup queries from
bash/starship/tmux pass through to Windows Terminal. Windows Terminal responds,
but the responses travel back through SSH→tmux and arrive too late — they
are no longer expected by the program that sent the query, so tmux renders
them as visible text. The DA1 query (`\e[c`) is likely sent by tmux itself
or by the shell to detect terminal capabilities.

**CLIPBOARD — SURPRISING:**
OSC 52 write PASSED inside tmux — tmux's native `set-clipboard on` + Ms
successfully sends clipboard data through SSH to Windows Terminal. Yet the
user reports clipboard is broken in practice. Possible explanations:
- `copy-pipe-and-cancel "tmux-yank.sh"` fires BOTH tmux-yank.sh's DCS
  passthrough AND tmux's native OSC 52 (via set-clipboard+Ms). The redundant
  DCS passthrough may interfere or confuse the sequence
- Clipboard write works but there's no way to paste FROM Windows clipboard
  back INTO the tmux session (right-click pastes tmux buffer, not system
  clipboard)
- The `bleopt: command not found` errors during bash startup may indicate
  .bashrc is partially broken, affecting shell behavior

**Also noted:** `bleopt: command not found` errors appear on tmux startup —
.bashrc runs `bleopt canvas_default_bg=...` inside tmux but ble.sh isn't
loaded in this environment

### Environment C: Kitty → SSH → Gitpod/ONA (Partially broken)

```
┌──────────────────────────────────────────────────────┐
│  Kitty (xterm-kitty, truecolor) on Mint              │
│  └─► SSH                                              │
│      │                                                │
│      ▼                                                │
│  ┌──────────────────────────────────────────────┐    │
│  │  Gitpod / ONA remote                          │    │
│  │  └─► tmux (same .tmux.conf synced)            │    │
│  │      ├─ set-clipboard on                       │    │
│  │      ├─ allow-passthrough on                   │    │
│  │      │                                          │    │
│  │      └─► bash (+ ble.sh if .bashrc synced)    │    │
│  │          └─ Copy: tmux-yank.sh                 │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
```

**Symptoms:**
- Clipboard from remote tmux does not reach local Kitty's system clipboard

**Diagnostic results (2026-02-19):**

Outside tmux (SSH into Gitpod, no tmux):
```
Host=ip-100-122-18-234 (AWS/Gitpod)
TERM=xterm-256color, COLORTERM=<unset>
Over SSH:           YES (UNKNOWN 65535 UNKNOWN 65535)
LANG:               en_US.UTF-8
OSC 52 write+read:  PASS (full round-trip!)
OSC 10:             PASS (rgb:d4d4/dada/f6f6 — Kitty's colors through SSH)
OSC 11:             PASS (rgb:1818/1818/2525 — Kitty's Catppuccin)
ble.sh:             NO
Clipboard tools:    <none>
Display server:     <none>
All checks passed!
```

Inside tmux (SSH+TMUX):
```
TERM=tmux-256color, TERM_PROGRAM=tmux 3.4
OSC 52 write:       PASS (verified via read-back!)
DCS passthrough:    PARTIAL (content mismatch)
OSC 10:             PASS (Kitty's colors through tmux+SSH)
OSC 11:             PASS (Kitty's colors through tmux+SSH)
DCS probe:          WARN (no response)
set-clipboard:      on
allow-passthrough:  on
Ms capability:      set (all 3 overrides)
escape-time:        0ms
tmux-yank.sh:       NOT FOUND at /home/vscode/.local/bin/tmux-yank.sh
ble.sh:             NO
No garbled characters on startup!
```

**Key findings:**
1. **OSC 52 works through the entire chain** (tmux→SSH→Kitty), both outside
   and inside tmux. The native `set-clipboard on` + Ms path is functional.
2. **tmux-yank.sh is MISSING on Gitpod** — the copy-pipe bindings reference
   `~/.local/bin/tmux-yank.sh` but the file doesn't exist at
   `/home/vscode/.local/bin/tmux-yank.sh`. Copy-pipe bindings that reference
   this script silently fail (the pipe target doesn't exist, so text is
   discarded instead of being processed).
3. **No garbled characters** — unlike Env B. The Gitpod .tmux.conf may be
   slightly different, or the startup programs don't send DA1/color queries.
4. **No clipboard tools at all** — xclip, xsel, wl-copy are all absent.
   OSC 52 is the ONLY viable clipboard path.
5. **OSC 10/11 return Kitty's colors** through tmux+SSH — `d4d4/dada/f6f6`
   and `1818/1818/2525` are the local Kitty Catppuccin colors, not remote
   terminal colors. This confirms escape sequences traverse the full chain.

**Root cause of Env C clipboard issue:** The copy-pipe bindings reference
`~/.local/bin/osc52-copy` (NOT `tmux-yank.sh` — the Gitpod config is
different). If `osc52-copy` doesn't exist, copy-pipe silently fails.
The diag misleadingly checked for `tmux-yank.sh` instead of the actual
pipe target. (Diag script now fixed to detect actual pipe targets from
bindings.)

Even if `osc52-copy` exists, it's redundant: the script sends a direct
OSC 52 (`printf '\033]52;c;%s\a' "$data"`), but `set-clipboard on` + Ms
already does this natively when text is copied. Two OSC 52 writes fire.

**Gitpod .tmux.conf differences from Mint:**
- Prefix: `Ctrl+b` (remote) vs `Ctrl+a` (local)
- Status bar: blue = REMOTE indicator (vs green = LOCAL)
- No F12 nested toggle (not needed — Ctrl+a vs Ctrl+b handles nesting)
- Copy pipe: `osc52-copy` instead of `tmux-yank.sh`
- `osc52-copy` sends DIRECT OSC 52, `tmux-yank.sh` sends DCS passthrough
- Both are redundant with `set-clipboard on` + Ms
- Has context menu on Ctrl+right-click
- Has help popup on `prefix + h`

---

## Escape Sequence Primer

### OSC 52 — Clipboard Access

OSC (Operating System Command) 52 lets a program inside a terminal read/write
the system clipboard without needing X11/Wayland access.

**Write to clipboard:**
```
\e]52;c;<base64-encoded-text>\a
│  │  │  │                    └─ BEL (0x07) terminates the sequence
│  │  │  └─ The text, base64-encoded
│  │  └─ "c" = clipboard selection (vs "p" for primary)
│  └─ "52" = clipboard command
└─ ESC ] = OSC introducer
```

Example — put "hello" on clipboard:
```
printf '\e]52;c;%s\a' "$(echo -n hello | base64)"
# Sends: \e]52;c;aGVsbG8=\a
```

**Read from clipboard (query):**
```
\e]52;c;?\a
```
Terminal responds with `\e]52;c;<base64-data>\a` if it supports read-back.
Many terminals support write-only (no read-back) for security.

### DCS Passthrough — Escaping Through tmux

DCS (Device Control String) passthrough lets escape sequences "tunnel" through
tmux to reach the outer terminal. Needed because tmux interprets most escape
sequences itself rather than forwarding them.

**Format:**
```
\ePtmux;\e<escaped-sequence>\e\\
│       │  │                 └─ ST (String Terminator)
│       │  └─ The inner sequence, with each \e doubled to \e\e
│       └─ "tmux;" prefix tells tmux this is passthrough
└─ ESC P = DCS introducer
```

Example — OSC 52 clipboard write through tmux:
```
\ePtmux;\e\e]52;c;<base64>\a\e\\
```

This is exactly what `tmux-yank.sh` sends:
```bash
printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$(echo -n "$buf" | base64)"
```

**Requires:** `set -g allow-passthrough on` in tmux.conf.

### OSC 10/11 — Terminal Color Queries

Programs (like ble.sh and starship) query the terminal's foreground/background
colors to adapt their output.

**OSC 10 — Query foreground color:**
```
\e]10;?\a
```
Terminal responds: `\e]10;rgb:RRRR/GGGG/BBBB\a`

**OSC 11 — Query background color:**
```
\e]11;?\a
```
Terminal responds: `\e]11;rgb:RRRR/GGGG/BBBB\a`

These are the likely source of the garbled characters in Environment B.

### The Ms Terminal Capability

The `Ms` capability tells tmux how to generate OSC 52 clipboard sequences.
It takes TWO parameters via ncurses `tparm()`:

```
Ms=\E]52;%p1%s;%p2%s\7
         ^^^^   ^^^^
         │      └─ %p2%s = base64-encoded selection data
         └─ %p1%s = selection target (e.g. "c" for clipboard)
```

**CRITICAL (tmux #4081):** The common single-param format `Ms=\E]52;c;%p2%s\7`
(hardcoded "c", missing `%p1`) is **silently rejected** by ncurses `tparm()` in
tmux 3.4+. No error, no clipboard — text only goes to the paste buffer.

In tmux 3.2+, the preferred approach is `terminal-features` instead of manually
setting Ms. The default `terminal-features` entry `xterm*:clipboard` already
sets the correct two-parameter Ms for any terminal matching `xterm*` (including
`xterm-kitty` and `xterm-256color`). Setting Ms in `terminal-overrides` can
**override and break** the correct default.

**Execution order:** `terminal-features` are applied FIRST, then
`terminal-overrides` override them. So a broken Ms in overrides will replace
the working one from features.

---

## Problem Hypotheses

### Environment B: Garbled Characters on Startup — CONFIRMED

**Root cause: CONFIRMED.** Escape sequence responses from Windows Terminal
leak through tmux's `allow-passthrough on` and render as visible text.

The captured garbage:
```
^[[?61;4;6;7;14;21;22;23;24;28;32;42;52c^[]10;rgb:bebe/bebe/bebe^[\^[]11;rgb:0000/0000/0000^[\
```

Decoded:
1. **DA1 response** (`^[[?61;...;52c`) — Windows Terminal responding to a
   Device Attributes query (`\e[c`). Likely sent by tmux on attach or by
   bash/starship during startup.
2. **OSC 10 response** (`^[]10;rgb:bebe/bebe/bebe`) — foreground color
3. **OSC 11 response** (`^[]11;rgb:0000/0000/0000`) — background color

**Important correction:** ble.sh is NOT loaded in Env B tmux (diag shows NO).
The queries come from tmux itself, starship, or bash — not ble.sh. Starship
is known to send DA1 queries for feature detection.

**Why it works in Env A:** Kitty handles these query/response round-trips
within the local Kitty↔tmux PTY with minimal latency. Responses arrive
before the prompt renders and are consumed by the requesting program.

**Why it breaks in Env B:** SSH adds latency to the round-trip. By the time
Windows Terminal's responses travel back (WinTerm→WSL→SSH→tmux), the
requesting program has moved on. The late responses arrive as unexpected
input and render as visible characters.

### Environment B: Clipboard — PARTIALLY CONFIRMED

**The OSC 52 write path works!** Diag confirmed PASS for OSC 52 write inside
tmux. tmux's native `set-clipboard on` + Ms successfully sends clipboard data
through the entire chain: tmux→SSH→WSL→Windows Terminal.

**However, user reports clipboard is "broken."** Open question: does the copied
text actually appear on the Windows clipboard? The user couldn't copy text out
of the tmux session, but this may be a UX/workflow issue rather than a protocol
failure:
- `paste-buffer` (right-click) pastes from the tmux buffer, not from the
  Windows system clipboard
- The user may need to use Ctrl+V (or Shift+Insert) to paste the system
  clipboard, which is a different path
- tmux-yank.sh's DCS passthrough fires alongside tmux's native OSC 52,
  potentially sending duplicate/conflicting clipboard writes

### Environment C: Clipboard Doesn't Reach Local Kitty — CONFIRMED

**Root cause: CONFIRMED.** The Gitpod config uses `~/.local/bin/osc52-copy`
(not `tmux-yank.sh`) as the copy-pipe target. If this script doesn't exist
or isn't executable, copy-pipe silently fails and clipboard text is lost.

Meanwhile, tmux's native `set-clipboard on` + Ms path works perfectly —
the diagnostic confirmed OSC 52 write PASS through the full tmux→SSH→Kitty
chain.

Even if `osc52-copy` exists and works, it's redundant — it sends a direct
OSC 52, and tmux's `set-clipboard on` already sends one via Ms. Two writes
fire simultaneously.

**All original hypotheses were wrong.** The issue isn't DCS passthrough
failing to traverse SSH, it isn't TERM mismatch, and SSH passes escape
sequences transparently. It's either a missing/broken pipe script, or the
pipe script conflicting with the native clipboard path.

---

## Test Matrix

What each diagnostic test checks and expected results per environment.

### tmux-diag.sh Tests

| Test | Env A (Local) — TESTED | Env B (Win→SSH→tmux) — TESTED | Env C (Kitty→SSH→Gitpod) — TESTED |
|---|---|---|---|
| **TERM value** | tmux-256color | tmux-256color (xterm-256color outside) | tmux-256color (xterm-256color outside) |
| **Inside tmux?** | YES (tmux 3.4) | YES (tmux 3.4) | YES (tmux 3.4) |
| **Over SSH?** | NO | YES (10.0.0.193→148) | YES (UNKNOWN 65535) |
| **ble.sh loaded?** | NO (inside tmux) | **NO** | **NO** |
| **OSC 52 write** | **PASS** | **PASS** | **PASS** |
| **OSC 52 read** | **PASS** | **PASS** | **PASS** |
| **DCS passthrough** | **PARTIAL** (redundant) | **PARTIAL** (mismatch) | **PARTIAL** (mismatch) |
| **OSC 10 query** | **PASS** | **WARN** (leaked on startup!) | **PASS** (Kitty colors) |
| **OSC 11 query** | **PASS** | **WARN** (leaked on startup!) | **PASS** (Kitty colors) |
| **set-clipboard** | on | on | on |
| **allow-passthrough** | on | on | on |
| **Ms capability** | Set (3 entries) | Set (3 entries) | Set (3 entries) |
| **xclip available?** | YES (X11 :0) | YES (but no DISPLAY) | **NO** (none) |
| **tmux-yank.sh** | Found | Found | **NOT FOUND** |

### clipboard-test.sh Tests

| Method | Env A — TESTED | Env B — TESTED | Env C — TESTED |
|---|---|---|---|
| OSC 52 direct | **PASS** | **PASS** (diag confirmed) | **PASS** (diag confirmed) |
| DCS passthrough | **PARTIAL** (redundant locally) | **PARTIAL** (mismatch) | **PARTIAL** (mismatch) |
| xclip | Available (X11 :0) | FAIL (no DISPLAY) | N/A (not installed) |
| tmux buffer | Works (local only) | Works (local only) | Works (local only) |

---

## Current tmux-yank.sh

Located at `~/.local/bin/tmux-yank.sh`:

```bash
#!/bin/bash
buf=$(cat)
echo -n "$buf" | tmux load-buffer -
printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$(echo -n "$buf" | base64)"
```

**Potential issue:** This always sends DCS passthrough regardless of whether
we're inside tmux. If tmux's `set-clipboard on` with Ms capability is already
handling OSC 52, the DCS passthrough may conflict. Also, the DCS passthrough
format assumes exactly one level of tmux nesting.

---

## Key Questions — Status

| # | Question | Status |
|---|---|---|
| 1 | Does Windows Terminal support OSC 52? Is it enabled? | **YES** — OSC 52 write PASS inside tmux. Native tmux→SSH→WSL→WinTerm path works. Read-back doesn't work (write-only). |
| 2 | Does the WSL PTY layer forward OSC 52 from SSH to Windows Terminal? | **YES** — confirmed. The full chain tmux(Ms)→SSH→WSL→WinTerm carries OSC 52. |
| 3 | Are the garbled characters in Env B actually OSC 10/11 responses? | **YES — TWO SEPARATE SOURCES.** (a) DA1 (`^[[?61;...;52c`) was from programs inside tmux using DCS passthrough — fixed by `allow-passthrough off`. (b) OSC 10/11 (foreground/background rgb) are from **tmux 3.4 itself** querying the outer terminal on client attach — fixed by `escape-time 50` + `window-style fg=default,bg=default`. Starship is NOT the source (confirmed: no OSC 10/11 querying code in starship). |
| 4 | Does `set-clipboard on` + Ms already handle OSC 52 natively? | **YES** — FIXED. The copy-mode→Ms path was broken because our Ms format was missing `%p1` (see #4081). Removing the broken Ms override and letting `terminal-features xterm*:clipboard` provide the correct format fixed it. tmux-yank.sh IS redundant and has been removed. |
| 5 | What does the remote TERM look like in Env C? | **ANSWERED** — `xterm-256color` outside tmux, `tmux-256color` inside. Ms capability set. Same as Env A/B. |
| 6 | Is `tmux-yank.sh` present on the remote machines (Env C)? | **NO** — not found at `/home/vscode/.local/bin/tmux-yank.sh`. This is the root cause of Env C clipboard failure. |
| 7 | What sends the OSC 10/11 queries that cause garbled output? | **ANSWERED** — tmux 3.4 itself sends `\e]10;?\e\\` and `\e]11;?\e\\` on client attach (confirmed in tmux#3838, tmux#4634, microsoft/terminal#18004). NOT starship (no OSC 10/11 code), NOT ble.sh (not loaded). Fix: `escape-time 50` + `window-style fg=default,bg=default`. |
| 8 | Why does user report clipboard broken if OSC 52 write PASS? | **ANSWERED** — The diag tests the APP→tmux OSC 52 path (printf). The COPY-MODE→Ms→OSC 52 path is a different code path and it does NOT work. In Env C: also missing pipe script. |
| 9 | Why doesn't copy-mode → Ms → OSC 52 work? | **ANSWERED (tmux #4081)** — Our `Ms=\E]52;c;%p2%s\7` was missing `%p1`. ncurses `tparm()` in tmux 3.4 silently rejects single-param Ms strings. Fix: removed Ms from `terminal-overrides`, let default `terminal-features xterm*:clipboard` set the correct two-param Ms. Kitty auto-detection was a red herring (tmux doesn't auto-detect Kitty features via XTVERSION). |

---

## Next Steps — ALL RESOLVED

All clipboard and garbled character issues have been fixed and verified on
all three environments: Env A (local), Env B (Windows→SSH→tmux), and
Env C (Kitty→SSH→Gitpod with `tmux-remote.conf` deployed).

---

## Fix Attempt #1 (2026-02-19) — FAILED

### What we tried

Created new tmux configs (`tmux-local.conf`, `tmux-remote.conf`) with:
1. `set -g allow-passthrough off` — to fix garbled chars in Env B
2. Removed `tmux-yank.sh` / `osc52-copy` from copy-pipe bindings
3. Used `copy-selection-and-cancel` (then tried `copy-pipe-and-cancel` no args)
4. Relied on native `set-clipboard on` + Ms to handle OSC 52 automatically

### What happened

Clipboard broke on LOCAL Env A (Kitty + tmux on Mint). Copying in copy-mode
(select with mouse or `v`+`y`) no longer put text on the system clipboard.
Only tmux's internal paste buffer was set (right-click paste worked, but
Ctrl+Shift+V in other apps did not paste the yanked text).

### What we verified during debugging

1. `tmux list-keys | grep 'copy-mode-vi.*y '` confirmed binding was active
2. `tmux display-message -p "#{client_termtype}"` → `kitty(0.32.2)`
3. `tmux show -g set-clipboard` → `on`
4. `tmux show -g terminal-overrides` → all three Ms entries present
5. `printf '\e]52;c;%s\a' "$(echo -n 'NATIVE_TEST' | base64)"` inside
   tmux → **system clipboard WAS set** (Ctrl+Shift+V pasted it inside tmux)
6. Copy-mode yank (v + y) → **system clipboard NOT set** (only tmux buffer)

### Key insight

There are TWO different OSC 52 paths in tmux:

**Path A — App → tmux (WORKS):**
An application inside tmux outputs `\e]52;c;...\a`. tmux's input handler
sees the OSC 52, and with `set-clipboard on`, forwards it to the outer
terminal. This is what the diag tests with printf. This is what tmux-yank.sh
uses (via DCS passthrough that tmux unwraps). **This path works.**

**Path B — Copy-mode → Ms (BROKEN on this setup):**
User yanks in copy-mode. tmux calls `window_copy_copy_buffer()`, checks
`set-clipboard != off`, generates OSC 52 using the Ms capability from
`terminal-overrides`, sends to outer terminal. **This path does NOT work
on this setup, despite the tmux source code saying it should.**

The old config worked because tmux-yank.sh used Path A (DCS passthrough →
tmux unwraps → sends OSC 52 to outer terminal). We mistakenly assumed
Path B was working and removed tmux-yank.sh.

### Possible causes for Path B failure (to investigate)

- **Kitty auto-detection:** `client_termtype: kitty(0.32.2)` shows tmux
  detected Kitty via extended terminal detection (not just TERM=xterm-kitty).
  tmux 3.3+ has built-in terminal features for known terminals. The auto-
  detected features may conflict with or override the manual Ms in
  `terminal-overrides`. Need to check `terminal-features` and whether
  Kitty's built-in feature set includes/excludes clipboard.
- **Plugin interference:** tmux-sensible, catppuccin, or another plugin
  may modify clipboard-related settings or override bindings.
- **tmux build:** The tmux 3.4 binary may have been built without certain
  features, or there's a version-specific bug with Ms + Kitty.
- **Something in .bashrc / shell startup** that interferes with tmux's
  terminal capability detection.

## Fix Attempt #2 (2026-02-19) — SUCCESS (Env A)

### Root cause: Malformed Ms capability (tmux issue #4081)

The Ms string `\E]52;c;%p2%s\7` in our `terminal-overrides` was missing `%p1`.
ncurses `tparm()` in tmux 3.4 requires both parameters and silently rejects
single-param formats. The expansion fails, no OSC 52 is sent, text only goes
to the paste buffer.

Worse: tmux's default `terminal-features` (`xterm*:clipboard`) already sets the
CORRECT two-parameter Ms (`\E]52;%p1%s;%p2%s\a`). Our `terminal-overrides` ran
AFTER `terminal-features` and **overwrote the working Ms with a broken one**.

### What we changed

1. Removed `Ms=\\E]52;c;%p2%s\\7` from all `terminal-overrides` entries
2. Kept only `RGB` in terminal-overrides (for truecolor support)
3. Let default `terminal-features xterm*:clipboard` provide the correct Ms
4. Changed copy bindings from `copy-pipe-and-cancel` to `copy-selection-and-cancel`
5. `allow-passthrough off` (fixes garbled chars in Env B)
6. Removed all pipe script dependencies (tmux-yank.sh, osc52-copy)

### Config (relevant section)

```
set -g terminal-overrides ""
set -ag terminal-overrides ",xterm-kitty:RGB"
set -ag terminal-overrides ",xterm-256color:RGB"
set -ag terminal-overrides ",tmux-256color:RGB"
set -g set-clipboard on
set -g allow-passthrough off
# ... bindings:
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel
```

### Result

**Env A: WORKING.** Mouse drag-select copies to system clipboard. Confirmed
via Ctrl+Shift+V in other applications.

### Why this fixes all three problems

| Problem | How it's fixed |
|---|---|
| Clipboard (all envs) | Native copy-mode→Ms→OSC 52 now works (correct Ms format from terminal-features) |
| Garbled chars (Env B) | `allow-passthrough off` blocks DA1/OSC 10/11 response leaks |
| External script deps | Eliminated — no tmux-yank.sh, no osc52-copy |

### Key research findings (from tmux source analysis)

- **tmux #4081**: explicit confirmation from maintainer that single-param Ms fails
- **Kitty XTVERSION**: tmux detects Kitty via XTVERSION (`kitty(0.32.2)`) but does
  NOT auto-apply any Kitty-specific features — Kitty is not in tmux's recognized
  terminal list (only iTerm2, XTerm, mintty, foot, tmux are recognized)
- **Feature precedence**: `terminal-features` apply FIRST, `terminal-overrides` SECOND
  (overrides win, which is why our broken override replaced the working default)

## Fix Attempt #3 (2026-02-19) — FULL SUCCESS (Env A + Env B verified)

### Problem: OSC 10/11 garbled text persisted after Fix #2

Fix #2 resolved clipboard and DA1 leaks, but OSC 10/11 responses still appeared
as garbled text in Env B: `^[]10;rgb:bebe/bebe/bebe^[\^[]11;rgb:0000/0000/0000^[\`

The DA1 response (`^[[?61;...;52c`) was gone — `allow-passthrough off` worked
for that. But OSC 10/11 came through a different mechanism.

### Root cause: tmux 3.4 queries outer terminal colors on client attach

tmux 3.4 introduced querying the outer terminal for fg/bg colors on client
attach by sending `\e]10;?\e\\` and `\e]11;?\e\\` directly (not through DCS
passthrough). Over SSH, the responses are delayed and fragmented across TCP
packets. With `escape-time 0`, tmux's key parser can't reassemble them — the
bytes leak to the active pane as visible text.

**Confirmed NOT starship** — starship has no OSC 10/11 querying code (verified
by checking its Cargo.toml dependencies: no `termbg`, no `terminal-colorsaurus`).

Known tmux issue: tmux#3838, tmux#4634, microsoft/terminal#18004, gpakosz/.tmux#720.

### What we added

1. `set -s escape-time 50` — gives tmux 50ms to parse multi-byte escape
   sequences from the outer terminal over SSH (was 0ms). 50ms is imperceptible
   for keyboard input but sufficient for SSH byte reassembly.

2. `set -g window-style 'fg=default,bg=default'` + `window-active-style` —
   pre-sets pane colors so tmux may skip querying the outer terminal entirely.

### Result

**Env A: WORKING.** Clipboard works, no garbled text (was never an issue locally).
**Env B: WORKING.** Clipboard works (mouse drag → Ctrl+V in Windows). No garbled
characters on tmux startup. Clean session.

## Overall Conclusion

### Three root causes, three fixes

| Problem | Root Cause | Fix |
|---|---|---|
| Clipboard broken (all envs) | Malformed Ms in `terminal-overrides` — missing `%p1`, silently rejected by ncurses `tparm()` in tmux 3.4 (tmux#4081) | Remove Ms from overrides; let default `terminal-features xterm*:clipboard` provide correct two-param Ms |
| DA1 garbled text (Env B) | Programs inside tmux sent DA1 via DCS passthrough; responses leaked over SSH | `set -g allow-passthrough off` |
| OSC 10/11 garbled text (Env B) | tmux 3.4 itself queries outer terminal colors on client attach; responses fragmented over SSH with `escape-time 0` (tmux#3838) | `set -s escape-time 50` + `set -g window-style 'fg=default,bg=default'` |

### What we eliminated

- `tmux-yank.sh` — was the only working clipboard path (used Path A via DCS
  passthrough to work around broken Path B). No longer needed.
- `osc52-copy` — same concept, used on Gitpod config. No longer needed.
- `allow-passthrough on` — was required for tmux-yank.sh's DCS approach.
  No longer needed.
- External clipboard tool dependencies — OSC 52 is handled entirely by tmux.

### Script bugs fixed during Env A testing

1. **`((depth++))` with `set -e`** — Post-increment from 0 returns exit code 1
   (old value is falsy). Fixed: `depth=$((depth + 1))`.
2. **Stale `SSH_TTY` false positive** — tmux's `update-environment` doesn't
   include `SSH_TTY`, so it persists from previous SSH sessions. Fixed: only
   trust `SSH_CONNECTION` inside tmux, flag `SSH_TTY` as "MAYBE stale".
