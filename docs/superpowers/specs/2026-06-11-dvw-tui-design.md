# dvw TUI v1 — design

**Date:** 2026-06-11
**Status:** approved (brainstormed with vossi)
**Branch:** `feat/tui`

## Summary

A lazydocker-style terminal UI as dvw's new default experience: bare `dvw`
opens a persistent panel UI — workspace list on the left, live inspect detail
on the right, context menu for actions, full-screen doctor and orphans views.
Built with **Python + Textual**, reading the existing catalog-service API and
delegating all mutations to the existing bash command paths.

Replaces the gum top-level menu (which remains as fallback) and supersedes the
read-only web dashboard idea (`docs/catalog-service-future-ideas.md` in the
devmachine repo — idea #3, dropped).

## Decisions (settled during brainstorming)

| Decision | Choice |
|----------|--------|
| Stack | Python + Textual |
| Entry point | Bare `dvw` opens the TUI; all subcommands unchanged |
| v1 scope | Workspace list + actions, inspect pane, doctor view, orphans view. **No logs tab** (needs a new backend endpoint — deferred). |
| Connect UX | Per-IDE: GUI IDEs launch in background (TUI stays, toast); terminal sessions suspend the TUI, resume on exit |
| New-workspace wizard | Suspend TUI → existing gum wizard → resume + refresh (native Textual wizard later) |
| Refresh model | Poll only (no SSE — see ideas doc, #5 not-now) |
| Look & feel | First-class requirement: polished, Nord-themed, consistent with dvw's existing palette |

## Architecture

**Principle: the TUI reads the API; bash stays the actuator.**

```
┌──────────────────────── laptop / vossisrv ────────────────────────┐
│  dvw (bash entry)                                                 │
│   ├─ bare + TTY + runtime ok ──► tui/ (Textual app)               │
│   │                               │ reads: httpx over UDS         │
│   │                               │   GET /workspaces, /inspect,  │
│   │                               │   /containers/status, /orphans│
│   │                               │ mutates: subprocess           │
│   │                               │   dvw stop|start|rebuild|rm   │
│   │                               │   dvw <id> (connect), wizard  │
│   └─ otherwise ──► existing gum menu (fallback, with hint)        │
└───────────────────────────────────────────────────────────────────┘
```

- **No devpod orchestration is reimplemented in Python.** Every mutation goes
  through the proven bash paths as subprocesses; the TUI is a view +
  dispatcher. This keeps one source of behavior and keeps the bats suite
  authoritative for actions.
- **Transport:** the bash launcher guarantees a reachable catalog socket
  before exec'ing the TUI — locally on vossisrv it's the unix socket directly;
  remotely it reuses dvw's existing ssh ControlMaster machinery to forward it.
  The socket path is handed to the TUI via `DVW_CATALOG_SOCKET`; bearer token
  (if configured) via the existing config mechanism.
- **API client:** a small `CatalogClient` (httpx, UDS transport, async) with
  typed accessors for the endpoints used. No new server endpoints in v1.
- **Packaging/launch:** the `tui/` project is uv-managed; the bash launcher
  starts it via `uv run` (so deps self-install on first launch). "Runtime ok"
  in the entry check means `uv` is on PATH; `dvw doctor` and `dvw-install.sh`
  learn to check/install it.

## Components

```
tui/
├── pyproject.toml          # uv-managed; deps: textual, httpx
├── dvw_tui/
│   ├── app.py              # DvwApp: screens, bindings, polling worker
│   ├── client.py           # CatalogClient (httpx over UDS)
│   ├── actions.py          # subprocess dispatch to bash dvw + suspend logic
│   ├── screens/
│   │   ├── main.py         # workspace list + inspect pane
│   │   ├── doctor.py       # full-screen doctor report
│   │   └── orphans.py      # full-screen orphans list + remove action
│   ├── widgets/            # workspace table, inspect panel, confirm modal,
│   │   └── …               # context menu
│   └── theme.tcss          # Nord theme (single source of styling)
└── tests/                  # pytest: client (mocked transport) + pilot tests
```

| Unit | Does | Depends on |
|------|------|-----------|
| `client.py` | Async reads from catalog API | httpx, socket path from env |
| `actions.py` | Runs `dvw <subcmd>` subprocesses; decides background-vs-suspend per IDE; surfaces failures | bash dvw on PATH |
| `screens/*` | Render state, own their keybindings | client, actions, widgets |
| `app.py` | Wires screens, background poll worker, toasts, error banner | all of the above |

## Layout & keybindings

**Main screen** — left: workspaces table (state glyph ● ⚠ ○ ✗, id, repo@branch,
IDE); right: inspect pane for the focused workspace (state, health, mounts,
CPU/mem, disk, liveness), fetched on focus change. Header shows catalog host +
connection state; footer shows active keys (Textual `Footer`).

| Key | Action |
|-----|--------|
| `enter` | Connect (per-IDE semantics) |
| `s` / `S` | Stop / Start |
| `r` | Rebuild (confirm modal) |
| `X` | Remove (confirm modal; extra warning if running) |
| `n` | New workspace (suspend → gum wizard → resume + refresh) |
| `d` | Doctor screen |
| `o` | Orphans screen |
| `x` | Context menu listing all actions (lazydocker-style) |
| `/` | Filter the list |
| `R` | Manual refresh |
| `q` / `esc` | Quit / back |

**Doctor screen:** runs the existing doctor checks and renders the report in a
scrollable view with [OK]/[WARN]/[FAIL] styling. **Orphans screen:** rows from
`/containers/orphans` with a guarded remove action (confirm modal; never
auto).

## Refresh model

- Background worker polls bulk `GET /containers/status` (+ workspace list)
  every **10 s**.
- Immediate refresh after every action returns.
- `/inspect` fetched on focus (cached per workspace for the poll interval).
- No event stream; revisit only if this ever feels stale (ideas doc #5).

## Look & feel (first-class requirement)

- **Nord theme throughout**, matching dvw's existing palette: cyan accent,
  teal cursor-IDE, yellow ssh, blue vscode, peach jetbrains, green running,
  red stale/error, grey stopped/dim. One `theme.tcss` is the single source.
- Rounded panel borders, breathing room, no wall-of-text panes.
- State changes animate via toasts (`notify`): "stopped vossiman/dvw — freed
  1.8 GB"-style messages where data allows.
- Inspect pane uses definition-list style rendering, not raw JSON; CPU/mem as
  compact bars/sparklines where Textual makes it cheap.
- Loading states: skeleton/spinner, never a frozen screen; slow calls show
  progress hints like the CLI does today.
- Acceptance bar: a screenshot of the main screen should look *deliberate* —
  something you'd put in the README.

## Error handling

- Catalog unreachable → persistent red banner with retry key; the list dims
  rather than silently showing stale data. Box down = pods down, so no
  offline cache (ideas doc #13, dropped).
- Action subprocess fails → modal with captured stdout/stderr; TUI state
  refreshes regardless.
- TUI runtime missing / not a TTY → bash falls back to the gum menu and
  prints a one-line hint how to get the TUI.

## Testing

- **pytest** for `CatalogClient` (mocked UDS transport) and `actions.py`
  (subprocess calls mocked; per-IDE dispatch logic covered).
- **Textual pilot tests** for the screens: navigation, keybindings, confirm
  modals, error banner.
- **bats** suite untouched and must stay green; new bats coverage only for
  the bash launcher logic (TTY/runtime detection, fallback).

## Out of scope (v1)

Logs tab (needs backend endpoint), native Textual wizard, disk-usage tab
(ideas doc #6 — first TUI-native follow-up), SSE live updates, any
write-path changes to catalog-service.
