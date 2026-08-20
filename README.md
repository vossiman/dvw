# dvw — DevPod workspace orchestrator

Host-side scripts and operational notes for running DevPod workspaces on a shared Linux host (`vossisrv` in the reference deployment — host, user, and provider are all configurable, see [Configuration](#configuration-host-user-provider)). The main entrypoint is `dvw`, a bash CLI that replaces the DevPod Desktop app's missing cross-machine workspace sync via a catalog served by the **`dvw-catalog` service** on `vossisrv`. Each client reaches the catalog over SSH (`ssh vossisrv -- curl --unix-socket …`), so every machine sees the same workspaces. Container-side configuration (Claude/opencode/codex/cursor-agent + MCPs) lives in the sister repo [`vossiman/aiCodingBaseSetup`](https://github.com/vossiman/aiCodingBaseSetup), which also owns the canonical `.devcontainer/devcontainer.json` (see [Devcontainer for a workspace repo](#devcontainer-for-a-workspace-repo) below).

## Why dvw exists

The DevPod Desktop app stores workspace metadata locally per machine. Switching from Mint to WSL means the second machine sees an empty workspace list, even though all the containers are still running on `vossisrv`. `dvw` fixes that by recording every workspace in a central catalog served by the `dvw-catalog` service on `vossisrv`. Any client that has SSH access to the box and the dvw script sees the same workspaces and can connect, start, stop, and create new ones.

## Folder layout

| Path | Purpose |
|------|---------|
| `dvw` | CLI entrypoint (sources `lib/*`) |
| `lib/` | catalog, ssh-sync, connect, wizard, commands, UI |
| `catalog-service/` | the `dvw-catalog` HTTP service (runs on vossisrv) and its deploy scripts |
| `dvw-install.sh` | idempotent client bootstrap for Mint and WSL |
| `tests/bats/` | bats test suite for catalog logic |
| `tmux/` | host-side tmux config |
| `cursor-shim.sh`, `install-cursor-shim.sh` | Cursor AppImage triple-launch workaround |
| `KNOWN_ISSUES.md` | catalog of current rough edges |

## Subcommands

| Command | Effect |
|--|--|
| `dvw` | opens the TUI (requires `uv` + a tty); errors with the subcommand list if the TUI can't run |
| `dvw <id>` | connect via SSH (terminal + tmux `work` session) |
| `dvw <id> --ssh` | same as bare connect (explicit) |
| `dvw <id> --cursor` | open in Cursor via `devpod up --ide cursor` |
| `dvw <id> --both` | open in Cursor, then ssh + attach `work` tmux session |
| `dvw attach` | connect to the tmux window most recently flagged waiting-for-input (picker if several; reports and exits if none) — TUI equivalent: `a` (newest) or Enter on that window's row in the tree |
| `dvw push [<file>…] [--clipboard] [--to <ws>]` | copy a file into `/tmp/` of the workspace this machine is attached to and print the landed container path (bare: newest fresh Termius-style `/tmp` upload; `--clipboard`: clipboard image via wl-paste/xclip/PowerShell). Refuses a `--to` target the catalog doesn't report running. |
| `dvw -l` | list workspaces (MRU order) |
| `dvw new` | bare: opens the TUI's new-workspace wizard (same requirements as bare `dvw`). Flag-driven (no TUI/tty needed): `dvw new --repo <url> --name <name> --ide cursor\|ssh [--branch <b>] [--init-empty] [--seed-devcontainer] [--yes]` — creates the workspace and appends it to the catalog. See [Create a new workspace](#create-a-new-workspace). |
| `dvw rm <id>` | delete workspace + remove from catalog (confirm if running) |
| `dvw stop <id>` | `devpod stop` |
| `dvw start <id>` | `devpod up` with the workspace's saved IDE |
| `dvw recreate <id>` (alias `rebuild`) | rebuild the container (`devpod up --recreate`) — needed to pick up a changed `devcontainer.json` (mounts/hooks). Offers `pin-sync` first when the committed image pin is stale |
| `dvw pin-sync [<id>…]` | open a PR per workspace repo whose committed devcontainer image pin is behind the blueprint (no args = every catalog workspace) |
| `dvw update` | Update to the latest released tooling and refresh the version marker. Standalone checkout: pull `main` + reinstall. Submodule checkout: follow the parent's pins (ff the parent, check out pinned submodules, reinstall) — never commits or pushes. Startup/`dvw doctor` nudge when behind `origin/main`. |
| `dvw status` | one-line per workspace: id, repo@branch, ide, state (`● running` / `⚠ stale` / `○ stopped` / `✗ absent` / `? unreachable` / `? unknown`), last used |
| `dvw doctor` | health check: catalog endpoint + transport note, provider probe, catalog service, ssh-sync, devpod, per-orphan summary, duplicate-sibling containers |
| `dvw audit` | deeper per-orphan git audit (branch, modified file count, unpushed commit count, stash count, verdict) — one ssh per provider host |
| `dvw config` / `dvw config set KEY VALUE` | show or persist the per-machine config (catalog host, provider — see [Configuration](#configuration-host-user-provider)); runs even when the service is unreachable |
| `dvw <anything> --dry-run` | print would-be `devpod ...` / `docker ...` invocations without executing — works on any mutating subcommand |

## Server (catalog-service)

Runs on one Linux host (the reference deployment is `vossisrv`).

```bash
# first time, as your normal user on the catalog host (reference: vossi@vossisrv)
sudo install -d -o "$USER" -g "$USER" /opt/dvw
git clone -b main https://github.com/vossiman/dvw.git /opt/dvw
/opt/dvw/catalog-service/deploy/host-install.sh   # idempotent; installs+enables the systemd unit, smoke-tests /v1/health
```
The catalog starts empty. To seed it from an existing `catalog.json` (and
`ssh-blueprint.conf`), copy the files into `/var/lib/dvw-catalog/` and then
`sudo systemctl restart dvw-catalog.service` — the service loads + validates
them on startup. (`restart` is the passwordless verb from the sudoers drop-in;
`stop`/`start` would prompt for a password.)

Updates: `/opt/dvw/catalog-service/deploy/host-update.sh`. No TCP port — the service binds a unix socket; auth is SSH + `0660 vossi:vossi` socket perms. Full detail in [`catalog-service/README.md`](catalog-service/README.md). Verify:

```bash
ssh vossisrv -- curl --unix-socket /run/dvw-catalog/catalog.sock http://localhost/v1/health
```

## Client — on each laptop (Mint / WSL)

```bash
git clone https://github.com/vossiman/dvw
cd dvw
./dvw-install.sh     # installs jq/devpod, symlinks dvw into ~/.local/bin
dvw doctor
```

The installer is idempotent — re-run it any time.

**Requirement:** SSH access to the box — a `Host <alias>` entry in `~/.ssh/config` with key auth (the reference deployment uses alias `vossisrv`, user `vossi`). The client reaches the catalog via `ssh <alias> -- curl --unix-socket …`. The defaults are `DVW_CATALOG_HOST=vossisrv` and `DVW_CATALOG_SOCK=/run/dvw-catalog/catalog.sock`; point them at your own host with `dvw config set DVW_CATALOG_HOST <alias>` (see [Configuration](#configuration-host-user-provider)). Ensure `~/.local/bin` is on PATH (the installer warns if it isn't).

**WSL note:** the first run on a fresh WSL detects that systemd is not enabled, writes `/etc/wsl.conf`, and stops with:
> systemd is now enabled, but WSL must be restarted. From Windows PowerShell: `wsl --shutdown`. Then re-open WSL and re-run.

After `wsl --shutdown` and reopening WSL, re-run `./dvw-install.sh` and it continues from where it left off.

## Configuration: host, user, provider

`vossisrv` (host) and `vossi` (user) are just the reference deployment's
defaults — nothing in dvw is hardwired to them.

**Client** — pin per machine with `dvw config` (writes
`~/.config/dvw/config`; precedence is env > file > built-in default). `dvw config`
with no args prints the effective values:

```bash
dvw config set DVW_CATALOG_HOST myhost     # ssh alias of the catalog box (default: vossisrv)
dvw config set DVW_PROVIDER     myhost     # devpod provider name for new workspaces (default: vossisrv)
# also honored: DVW_CATALOG_SOCK, DVW_CATALOG_TOKEN
```

**Server** — `host-install.sh` runs as your normal user and rewrites the systemd
units' `User=`/`Group=` to whoever installs, so the service isn't tied to `vossi`.
The default devpod-provider name stamped on entries is `CATALOG_DEFAULT_PROVIDER`
(default `vossisrv`) in `catalog.env`; real catalog data overrides it per entry.

## Devcontainer for a workspace repo

`aiCodingBaseSetup` owns the canonical `.devcontainer/devcontainer.json`
(clone-based provisioning + the generic `${localEnv:HOME}/devpod/<name>` bind
mounts). dvw no longer ships a copy. To make a repo build into a proper
workspace, drop the canonical file into its `.devcontainer/`, then commit + push
so any future `dvw new` from that repo picks it up:

```bash
# 1. create the host state dirs the mounts bind to (once per host)
mkdir -p ~/devpod/{aicodingsetup,claude,opencode,codex,cursor}

# 2. pull the canonical devcontainer.json into the repo
mkdir -p .devcontainer
curl -fsSL https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/devcontainer.json \
  -o .devcontainer/devcontainer.json

# 3. commit + push so `dvw new` builds from it
git add .devcontainer && git commit -m 'add devcontainer' && git push
```

The mounts resolve `${localEnv:HOME}` on the **host** at provision time, so the
same file is portable across machines — no per-host editing needed.

## Installing as a submodule

If you're embedding `dvw` inside another repo (e.g. you maintain a meta-repo
like `devMachine`), use a submodule pointer rather than a fresh clone — the
parent repo's submodule ref then pins the dvw version, and bumps are explicit
single-commit changes.

    git submodule add https://github.com/vossiman/dvw devpod/dvw
    git add .gitmodules devpod/dvw
    git commit -m "devpod/dvw: add dvw submodule"
    ./devpod/dvw/dvw-install.sh

The PATH symlink (`~/.local/bin/dvw → <clone>/dvw`) is created by
`dvw-install.sh`, regardless of whether the clone is standalone or a
submodule checkout. Re-running `dvw-install.sh` from a different location
re-points the symlink — switching is safe.

## Updating dvw

Three update flows, depending on how you installed.

### Standalone clone

    cd <your-dvw-clone>
    git pull
    ./dvw-install.sh

`dvw-install.sh` is idempotent — re-running re-checks apt deps and re-creates
the `~/.local/bin/dvw` symlink.

### Submodule consumer

    dvw update

Follows the parent's pins: fast-forwards the parent repo to its `origin/main`,
checks every submodule out at the commit the parent pins, and re-runs
`dvw-install.sh`. Creates no commits — nothing to push. Refuses (naming the
blocker) if the parent is off `main`, has uncommitted changes, or can't
fast-forward.

To move the pin *forward* instead — a maintainer action that commits — bump it
in the parent:

    git submodule update --remote devpod/dvw
    git add devpod/dvw
    git commit -m "devpod/dvw: bump to <sha>"

### PATH symlink hygiene

`dvw-install.sh` re-symlinks `~/.local/bin/dvw → <clone>/dvw` on every run.
If you maintain multiple checkouts (e.g. one standalone clone on a Mint
laptop *and* a submodule checkout inside `devMachine`), the last-run
`dvw-install.sh` wins the symlink. The `dvw` script itself is byte-identical
in every checkout (filter-repo'd from one source), so which checkout
the symlink points at is functionally irrelevant — pick whichever you
plan to keep up-to-date.

## Daily workflow

### Connect to a workspace

```bash
dvw                  # TUI
dvw <workspace-id>   # direct
dvw -l               # list and exit
```

### Create a new workspace

```bash
dvw new
```

Bare `dvw new` opens the TUI's new-workspace wizard (same requirements as bare `dvw`: `uv` + a tty; `DVW_NO_TUI=1` makes it error out naming the reason instead). In the wizard: pick repo (from the catalog's saved list, or enter a new URL) → branch (picker of the branches that exist on the remote, sorted, first one highlighted) → workspace name (auto-suggested) → IDE (defaults to the catalog's `ide` default, `cursor` when unset) → confirm. On success, `devpod up` runs and the catalog is updated.

For scripting, or when the TUI can't run, drive it with flags instead — no prompts, no tty required:

```bash
dvw new --repo <url> --name <name> --ide cursor|ssh \
  [--branch <branch>] [--init-empty] [--seed-devcontainer] [--yes]
```

- `--repo` (required) — clone URL. An `https://github.com/...` URL that fails over HTTPS (no credential helper in the devbox) is retried as its SSH form automatically; `dvw new` reports the swap.
- `--name` (required) — workspace ID; sanitized, capped at DevPod's 48-char limit, and rejected if it collides with an existing catalog or DevPod entry.
- `--ide` (required) — `cursor` or `ssh`.
- `--branch` — defaults to `main` when combined with `--init-empty`; otherwise required.
- `--init-empty` — if the repo has no branches yet, create an initial commit (seeded with the aiCodingBaseSetup blueprint `devcontainer.json` when reachable) instead of erroring.
- `--seed-devcontainer` — if the target branch has no `devcontainer.json` DevPod would find, commit the blueprint one before `devpod up`.
- `--yes` — skip the confirmation prompt (needed for non-interactive/scripted runs; without it, `dvw new` fails closed on a non-tty).

### Recreate a workspace cleanly

If you've changed mounts, postCreateCommand, or the base image — or you just want a fresh slate — see the manual recreate procedure (still required because of root-owned bind mounts):

```bash
dvw rm <workspace-id>
ssh -t vossi@vossisrv 'sudo rm -rf /home/vossi/.devpod/agent/contexts/default/workspaces/<workspace-id>'
dvw new
```

The `sudo rm` step requires interactive auth; don't try to script past it.

## Updating a running container

Two mechanisms, depending on what changed:

- **New aiCodingBaseSetup (config + CLIs) — no rebuild.** Inside the container: `aicoding-status` (what's behind), `aicoding-sync` (pull latest blueprint, reconcile config, update CLIs). Also runs automatically on every container start (`on-start.sh` → `aicoding-sync --boot`).
- **Updated `devcontainer.json` (mounts/provisioning) — needs rebuild.** Mounts are fixed at container-create time, so from the laptop: `dvw recreate <id>`.
- **New base image — rebuild, but mind the pin.** `devpod up --recreate` builds from the image pinned in the repo's *committed* `.devcontainer/devcontainer.json`. `aicoding-sync` refreshes that file in the container working tree but never commits it, so the repo copy drifts and a rebuild silently reinstalls the old image. `dvw pin-sync` opens the PR that fixes it; `dvw rebuild` also offers to run it when it spots a stale pin. Nothing does this on a schedule — run it when the ⬆rebuild badge shows up.

## Multi-machine sync model

A single user across multiple machines (e.g. laptop + WSL on a PC), one remote provider (`vossisrv`), one central catalog served by the catalog service. Three pieces of state participate:

- **Catalog (the catalog service)** — served by `dvw-catalog` on `vossisrv`, reached over SSH. Authoritative for *which workspaces exist*: id, repo, branch, ide, provider name. Also caches a per-workspace `.devpod_state` snapshot opportunistically. **The catalog `.uid` is a convenience copy; the agent is authoritative for the actual id↔uid mapping** (see below).
- **Client workspace.json (per-machine)** — `~/.devpod/contexts/default/workspaces/<id>/workspace.json`. DevPod CLI's local record on each client. Layout: `{ "id": ..., "uid": ..., "provider": { "options": { "HOST": ... } }, ... }` (fields at top level).
- **Agent workspace.json (on the provider)** — `~/.devpod/agent/contexts/default/workspaces/<id>/workspace.json` on `vossisrv`. DevPod agent's record. Layout: `{ "workspace": { "uid": ..., "provider": ... }, ... }` (fields nested under `.workspace`). **This is authoritative** — the agent uses *its own* workspace.json to pick which docker container to exec into, so any client uid that disagrees with the agent's is wrong from DevPod's perspective.

`dvw` aligns the local client uid on every connect path via `_dvw_resolve_canonical_container` (`lib/connect-resolver.sh` → catalog-service `GET /v1/workspaces/{id}/container`): the service picks the canonical container (bind-mount + tmux tie-break), the client rewrites local `.uid` if needed and pushes `devpod_state` to the catalog. Drift heals automatically. The status probe (`_dvw_load_probe` → `GET /v1/containers/status`) also joins id↔uid *server-side*, so a fresh machine with no local DevPod state still gets correct `dvw status` on the first run.

For why this matters and what the failure mode looks like when it breaks, see the uid-drift entry in `KNOWN_ISSUES.md`.

## Provider probe (`dvw status` / `dvw doctor` ground truth)

`dvw status`, `dvw doctor`, and the picker compute workspace state from the **catalog service** on the provider (`GET /v1/containers/status` + `/orphans` via `lib/connect-resolver.sh`), not from client-side SSH docker fan-out. The service does one local docker pass, joins agent workspace dirs to container labels, and returns per-id liveness plus orphan detail.

Five user-visible states:

| State | Meaning |
|--|--|
| `● running` | Container running, `/proc/1/cwd` is a live inode |
| `⚠ stale` | Container running, but bind mount points at a deleted inode (Cursor will fatal — `dvw recreate <id>` to fix) |
| `○ stopped` | Container exists on provider, not running (`dvw start <id>` to start) |
| `✗ absent` | Catalog says the workspace exists, but no container on the provider has a matching uid (someone deleted it manually, or uid drift the reconciler hasn't fixed yet) |
| `? unreachable` | The catalog service couldn't be reached from this machine. **Distinct from `○ stopped`** — it means "I can't ask," not "container is down." Detail appears in the `dvw status` / `dvw doctor` footer. |

`dvw doctor` opens with a `[OK] provider probe: alive=N stale=N stopped=N absent=N` summary or fails noisily if the probe couldn't reach the provider.

## Duplicate sibling containers

Distinct from orphans. An **orphan**'s workspace id is *absent* from the catalog;
**siblings** are two live containers for a workspace the catalog knows about, so
the orphan check cannot see them.

They deadlock connect: the resolver refuses to pick between siblings unless
exactly one has a live tmux `work` session, while `dvw status` shows the
workspace as plain `● running` (bulk status picks an arbitrary winner). Before
2026-07, that combination produced `dvw doctor` reporting **"✓ all checks
passed"** while `dvw <id> --ssh` hard-failed on the same workspace.

Now `dvw doctor` names it:

```
[WARN]  duplicate container(s): a workspace has >1 running container — connect will refuse it
         roleplaygame-git-develop · 2 running containers
```

Recovery, in order — no deletion required to get back in:

```bash
# 1. identify the siblings
curl -sS --unix-socket /run/dvw-catalog/catalog.sock \
  http://localhost/v1/workspaces/<id>/container      # -> sibling_ids

# 2. break the tie: give the REAL one a `work` session
docker exec <live-id> tmux new-session -d -s work

# 3. only then, after checking it for unpushed work, remove the other
docker rm -f <dead-id>
```

Tell the siblings apart by whether `/workspaces` inside is still `root`-owned
(never finished provisioning) and whether the mount source still exists.

Creation is guarded: `_dvw_safe_devpod_up` takes a per-workspace lock, so two
concurrent `devpod up` runs for one id can no longer produce a sibling pair.
Override the lock location with `DVW_UP_LOCK_DIR`; a stale lock prints the
`rmdir` needed to clear it.

## Action log

Every mutating shellout (`devpod up`/`delete`/`stop`, `docker restart`, …) funnels
through `_dvw_run_or_print`, which appends one line to `~/.dvw/actions.log`:

```
2026-07-26T07:36:27Z	pid=48213	devpod up roleplaygame-git-develop --ide none
```

Point it elsewhere with `DVW_ACTION_LOG`, or set `DVW_ACTION_LOG=/dev/null` to
disable. Logging is fail-open — an unwritable path never breaks the command.

It exists because dvw previously had no logging at all, which left "did
something run `devpod up` twice?" unanswerable after the fact.

## Orphan containers

When DevPod recreates a workspace (`devpod up --recreate`, or `devpod up` after editing devcontainer config), the previous container is left running under its old uid. `dvw doctor` surfaces these as orphans:

```
[WARN]  2 orphan container(s) on provider — may contain data, verify before removing
          default-da-89c70 · heuristic_spence · running · /workspaces/dataenv-git-devpod mount alive (may contain data)
          default-fi-2bae9 · jolly_lovelace  · exited  · /workspaces/financepdfs-git-main mount stale (deleted inode — workspaces data unrecoverable)
         (run `dvw audit` for git status / unpushed / stashes inside each)
```

The `dvw` TUI's `o` key lists orphan containers and lets you remove one (confirm, then a suspended `docker rm -f` you see before it runs). For the deeper per-orphan git audit — branch, modified file count, unpushed commit count, stash count, verdict — run `dvw audit` from a shell; it does one ssh per provider host and reports before you decide what to remove.

## SSH config sync

The ssh-blueprint now lives in the catalog service at `/v1/blueprint` (single
source of truth). On every `dvw` invocation, `lib/ssh-sync.sh` fetches the
blueprint and refreshes the local copy at `~/.ssh/dvw.conf` if it differs. Your
real `~/.ssh/config` is untouched apart from one `Include "dvw.conf"` line that
the installer prepends at the top of the file.

The seeded blueprint contains a `Host *.devpod` block with `ControlMaster auto`
for SSH multiplexing — first connect to a workspace takes ~2s, every subsequent
ssh to the same host within 10 minutes is near-instant (~5ms; verified: 400×
speedup on second connect). `ServerAliveInterval 5` + `ServerAliveCountMax 3`
detect a dead underlying transport after roughly 15 seconds. When an interactive
`dvw <id>` SSH session loses that transport, dvw clears any stale multiplex
master and automatically reattaches the same `work` tmux session with a 1s/2s/5s
retry backoff. Clean tmux detach or logout still returns immediately; press
Ctrl-C during a reconnect delay to stop retrying.

Reconnecting is gated on whether a connection ever happened, because ssh exits
255 both for a dropped transport and for a bad host key or refused auth, and the
exit status cannot tell them apart. dvw asks OpenSSH directly rather than reading
its messages: `-o LocalCommand=touch <marker>` is a client-side hook OpenSSH runs
only after a connection authenticates, so the marker file is proof. A live
multiplex master counts too — one cannot exist unless an earlier connection
authenticated — which matters because OpenSSH skips the hook for a session riding
an existing master. Until something proves a connection happened, a 255 returns
immediately with ssh's own error on screen.

`DVW_SSH_RECONNECT_TOTAL_MAX` (50) then bounds reconnects for the whole
invocation and is **never** reset by anything — a host that accepts and instantly
closes is otherwise indistinguishable from a flaky link, and every earlier
version of this loop that bounded itself with a resettable counter could be held
open forever. Reconnect attempts (not the first connect, which may legitimately
be slow on a cold container) also carry a short `ConnectTimeout`, so 50 attempts
against a dead network cannot add up to an unbounded wait. When dvw gives up it
tells you to rerun `dvw <id>`; the remote `work` session is untouched in every
case.

The OpenSSH behaviour this relies on is verified against a real sshd by
`tests/manual/verify-ssh-localcommand.sh` (11 checks, including a genuine
transport cut). It needs sudo, so it is not part of `tests/bats/run.sh` — run it
by hand when changing the reconnect loop or moving to a new OpenSSH major
version.

The 15s detection window is a deliberate trade: it also means a network blip
longer than 15s tears down an *idle* multiplex master and costs the next connect
its ~400× speedup. Raise it for your fleet by putting `ServerAliveInterval` in
the custom overrides (`PUT /v1/blueprint/custom`) — custom directives render
above the managed block and OpenSSH takes the first value it sees.

The catalog service generates the managed part of the blueprint. Deploying a
newer service version therefore updates managed defaults, including reconnect
keepalives, without a one-time API edit on every installation. On first access
after an upgrade, the service backs up a legacy `ssh-blueprint.conf`, removes
recognized old defaults, preserves everything else as custom overrides, and
atomically rematerializes the effective file. Custom directives come first so
OpenSSH's first-value-wins rules keep local policy authoritative. `dvw doctor`
reports the active managed-defaults version.

**Why the Include sits at the top of `~/.ssh/config`:** OpenSSH
propagates the enclosing Host block's `activep` flag into `Include`
directives. An Include nested inside a non-matching Host block silently
shadows its content for the queried hostname. Top-of-file = no
enclosing Host block = options apply. `dvw doctor` flags an
incorrectly-positioned Include and the installer auto-relocates a
stale one. DevPod's per-workspace stanzas live below the Include but
still apply (they match by exact hostname before `Host *.devpod`'s
wildcard pattern is evaluated).

Private SSH keys are **not** synced via dvw; use per-machine keypairs and
list both pubkeys in each server's `authorized_keys`.

## Cursor shim (cursor-shim.sh)

Wrapper that lets DevPod launch Cursor without spawning multiple windows per `devpod up`.

**Why it exists:** DevPod calls `cursor` three times when opening a workspace — `--list-extensions`, `--install-extension`, `--new-window`. The first two should be silent CLI calls; only the third opens a window. The raw Cursor AppImage entrypoint always opens a GUI window regardless of arguments, so without the shim you get three Cursor windows on every `devpod up`.

The shim points DevPod at Cursor's internal CLI wrapper (`squashfs-root/usr/share/cursor/bin/cursor`), which correctly dispatches CLI flags vs window-open. It auto-re-extracts the AppImage when its mtime changes, so daily Cursor updates don't break anything.

**Install:**

```bash
./devpod/install-cursor-shim.sh
```

Prerequisites:
- Cursor AppImage at `~/AppImages/cursor.appimage`
- `~/.local/bin` on PATH (installer warns if missing)

## Hook-firing rules (subtle but bites)

| Hook | Fires |
|------|---|
| `postCreateCommand` | Once when container is first built. Never again. |
| `postStartCommand` | Every container start: initial create-time start AND after `devpod stop` → `devpod up`, vossisrv reboots, etc. **NOT on simple reattach when the container is already running.** |

Editing `.devcontainer/devcontainer.json` after a container exists doesn't update the in-place container — DevPod baked the old hooks at creation. Recreate to apply new hooks.

## TUI

Bare `dvw` opens a lazydocker-style TUI (requires [uv](https://docs.astral.sh/uv/)
and a tty). Without `uv`, without a tty, or with `DVW_NO_TUI=1`, bare `dvw`
errors with the subcommand list instead — there's no menu fallback.

- left: a tree — each workspace is a folder (name, repo@branch, ide, live
  state incl. `⇄ N` attached clients); a running workspace auto-expands to
  its tmux windows, each shown as `name`, current command, `*` if active,
  activity age, and `⏸ waiting <age>` when an agent flagged it waiting for
  input; stopped workspaces are childless. Collapse/expand state survives
  refreshes.
- the header shows `⏸ N waiting` when anything across any workspace is
  waiting for input
- right: inspect detail (health, mounts, cpu/mem, disk) for the focused workspace
- `enter` / double-click on a window row → attach that tmux window; on a
  workspace folder → plain ssh session
- `a` attach to the newest waiting window · `x` menu (ssh / cursor / both + lifecycle)
- `s`/`S` stop/start · `r` rebuild · `X` remove · `n` new
- `d` doctor · `o` orphans · `/` filter · `R` refresh · `q` quit

SSH connects suspend the TUI and resume when the session ends. Cursor (via the
`x` menu or `dvw <id> --cursor`) launches in the background and the TUI stays
up. All mutations run through the same bash code paths as the CLI.

### Settings

The TUI reads (hand-edited only — nothing writes it) `~/.config/dvw/tui.json`:

```json
{ "palette": "tokyo", "motion": true }
```

- `palette` — colour scheme name, default `"tokyo"`. Unknown names fall back
  to `"tokyo"` silently.
- `motion` — boot-splash animation, default `true`.

`DVW_TUI_MOTION=0` overrides `motion` regardless of the file (also accepts
`false`, `no`, `off`, or an empty value, case-insensitively) — the escape
hatch for CI and slow ssh links.

## Tests

```bash
./tests/bats/run.sh
```

Bash logic is covered by bats (`tests/bats/`, including wizard seed/probe and TUI launch). Catalog-service and TUI have their own pytest suites under `catalog-service/tests/` and `tui/tests/`.

## See also

- [`catalog-service/README.md`](catalog-service/README.md) — the `dvw-catalog` service (deploy, API)
- [`tmux/README.md`](tmux/README.md) — host-side tmux config installation
- [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) — current quirks log
