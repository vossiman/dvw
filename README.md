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
| `dvw` | top-level menu (Connect/New/Status/Stop/Start/Remove/Doctor) |
| `dvw <id>` | connect to workspace; prompts SSH (terminal + tmux) or Cursor (GUI), pre-selecting the catalog's saved IDE |
| `dvw <id> --ssh` | skip the prompt; ssh + attach `work` tmux session |
| `dvw <id> --cursor` | skip the prompt; open in Cursor via `devpod up --ide cursor` |
| `dvw <id> --both` | skip the prompt; open in Cursor, then ssh + attach `work` tmux session |
| `dvw -l` | list workspaces (MRU order) |
| `dvw new` | wizard: create a new workspace, append to catalog |
| `dvw rm <id>` | delete workspace + remove from catalog (confirm if running) |
| `dvw stop <id>` | `devpod stop` |
| `dvw start <id>` | `devpod up` with the workspace's saved IDE |
| `dvw recreate <id>` (alias `rebuild`) | rebuild the container (`devpod up --recreate`) — needed to pick up a changed `devcontainer.json` (mounts/hooks) |
| `dvw pair <id>` | print the paseo pairing QR for a remote device; auto-registers the `<id>.devpod` ssh alias + local devpod state first, so it works on a machine that has never connected this pod (no `devpod up`) |
| `dvw update` | Update dvw in place to latest main and refresh the version marker. dvw nudges you to run this (and `dvw doctor` reports it) when the checkout falls behind `origin/main`. |
| `dvw status` | one-line per workspace: id, repo@branch, ide, state (`● running` / `⚠ stale` / `○ stopped` / `✗ absent` / `? unreachable` / `? unknown`), last used |
| `dvw doctor` | health check: catalog endpoint + provider, provider probe, catalog service, ssh-sync, devpod, gum, per-orphan summary |
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
./dvw-install.sh     # installs jq/gum/devpod, symlinks dvw into ~/.local/bin
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

    git submodule update --remote devpod/dvw
    git add devpod/dvw
    git commit -m "devpod/dvw: bump to <sha>"

(Then run `./devpod/dvw/dvw-install.sh` if any new host-level prereqs landed
in the bumped version. The script's `--check-only` flag tells you whether
you need to.)

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
dvw                  # menu, defaults to Connect
dvw <workspace-id>   # direct
dvw -l               # list and exit
```

### Create a new workspace

```bash
dvw new
```

Wizard: pick repo (from saved list, or enter new) → branch (defaults to last-used per repo) → workspace name (auto-suggested) → IDE (defaults to `cursor`) → confirm. On success, `devpod up` runs and the catalog is updated.

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

## Multi-machine sync model

A single user across multiple machines (e.g. laptop + WSL on a PC), one remote provider (`vossisrv`), one central catalog served by the catalog service. Three pieces of state participate:

- **Catalog (the catalog service)** — served by `dvw-catalog` on `vossisrv`, reached over SSH. Authoritative for *which workspaces exist*: id, repo, branch, ide, provider name. Also caches a per-workspace `.devpod_state` snapshot opportunistically. **The catalog `.uid` is a convenience copy; the agent is authoritative for the actual id↔uid mapping** (see below).
- **Client workspace.json (per-machine)** — `~/.devpod/contexts/default/workspaces/<id>/workspace.json`. DevPod CLI's local record on each client. Layout: `{ "id": ..., "uid": ..., "provider": { "options": { "HOST": ... } }, ... }` (fields at top level).
- **Agent workspace.json (on the provider)** — `~/.devpod/agent/contexts/default/workspaces/<id>/workspace.json` on `vossisrv`. DevPod agent's record. Layout: `{ "workspace": { "uid": ..., "provider": ... }, ... }` (fields nested under `.workspace`). **This is authoritative** — the agent uses *its own* workspace.json to pick which docker container to exec into, so any client uid that disagrees with the agent's is wrong from DevPod's perspective.

`dvw` reconciles client→agent on every connect path (`_dvw_reconcile_uid` in `lib/connect.sh`): ssh to the provider, read the agent's `.workspace.uid`, rewrite the local `.uid` if it differs, push the new uid to the catalog. Drift heals automatically. The status probe (`_dvw_load_probe`) also does the id↔uid join *server-side*, so a fresh machine with no local devpod state still gets correct `dvw status` output on the first run.

For why this matters and what the failure mode looks like when it breaks, see the uid-drift entry in `KNOWN_ISSUES.md`.

## Provider probe (`dvw status` / `dvw doctor` ground truth)

`dvw status`, `dvw doctor`, and the picker compute workspace state from a **single ssh round-trip to the provider** rather than per-workspace alias probes. The remote script enumerates `~/.devpod/agent/contexts/default/workspaces/`, reads each workspace's uid from its workspace.json, joins with `docker ps -a --filter label=dev.containers.id` labels, and returns `<id> <state>` lines plus per-orphan detail.

Five user-visible states:

| State | Meaning |
|--|--|
| `● running` | Container running, `/proc/1/cwd` is a live inode |
| `⚠ stale` | Container running, but bind mount points at a deleted inode (Cursor will fatal — `dvw recreate <id>` to fix) |
| `○ stopped` | Container exists on provider, not running (`dvw start <id>` to start) |
| `✗ absent` | Catalog says the workspace exists, but no container on the provider has a matching uid (someone deleted it manually, or uid drift the reconciler hasn't fixed yet) |
| `? unreachable` | The probe couldn't ssh to the provider from this machine. **Distinct from `○ stopped`** — it means "I can't ask," not "container is down." The captured ssh error appears in the `dvw status` / `dvw doctor` footer. |

`dvw doctor` opens with a `[OK] provider probe: alive=N stale=N stopped=N absent=N` summary or fails noisily if the probe couldn't reach the provider.

## Orphan containers

When DevPod recreates a workspace (`devpod up --recreate`, or `devpod up` after editing devcontainer config), the previous container is left running under its old uid. `dvw doctor` surfaces these as orphans:

```
[WARN]  2 orphan container(s) on provider — may contain data, verify before removing
          default-da-89c70 · heuristic_spence · running · /workspaces/dataenv-git-devpod mount alive (may contain data)
          default-fi-2bae9 · jolly_lovelace  · exited  · /workspaces/financepdfs-git-main mount stale (deleted inode — workspaces data unrecoverable)
         (run `dvw` and pick "Audit orphan containers" for git status / unpushed / stashes inside each)
```

The `dvw` top menu shows **⚠ Audit orphan containers (N)** when N > 0. Choosing it runs a deeper audit per orphan: branch, modified file count, unpushed commit count, stash count, verdict. Removal is always manual — `dvw` prints the `ssh <host> 'docker rm -f <name>'` template; you type it after deciding.

## SSH config sync

The ssh-blueprint now lives in the catalog service at `/v1/blueprint` (single
source of truth). On every `dvw` invocation, `lib/ssh-sync.sh` fetches the
blueprint and refreshes the local copy at `~/.ssh/dvw.conf` if it differs. Your
real `~/.ssh/config` is untouched apart from one `Include "dvw.conf"` line that
the installer prepends at the top of the file.

The seeded blueprint contains a `Host *.devpod` block with `ControlMaster auto`
for SSH multiplexing — first connect to a workspace takes ~2s, every subsequent
ssh to the same host within 10 minutes is near-instant (~5ms; verified: 400×
speedup on second connect).

To roll out a config change to all machines, update the blueprint in the service
(`PUT /v1/blueprint`). The next `dvw` call on each machine refreshes its local
copy.

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

Bare `dvw` opens a lazydocker-style TUI (requires [uv](https://docs.astral.sh/uv/);
falls back to the gum menu without it, or with `DVW_NO_TUI=1`).

- left: workspaces with live state (● running / ⚠ stale / ○ stopped / ✗ absent)
- right: inspect detail (health, mounts, cpu/mem, disk) for the focused workspace
- `enter` connect · `s`/`S` stop/start · `r` rebuild · `X` remove · `n` new
- `d` doctor · `o` orphans · `x` menu · `/` filter · `R` refresh · `q` quit
- `x` → *pair remote (paseo)* — shows the pod's paseo pairing QR (remote
  control of coding agents from the paseo apps; same QR pairs every device).
  Pods get the daemon via aiCodingBaseSetup; manual fallback:
  `dvw connect <id>`, then `paseo daemon pair`.

GUI IDE connects (cursor/vscode/jetbrains) launch in the background and the TUI
stays up; terminal connects (ssh) suspend the TUI and resume when the session
ends. All mutations run through the same bash code paths as the CLI.

## Tests

```bash
./tests/bats/run.sh
```

Catalog logic is covered by bats. Wizard and TUI behavior is verified manually.

## See also

- [`catalog-service/README.md`](catalog-service/README.md) — the `dvw-catalog` service (deploy, API)
- [`tmux/README.md`](tmux/README.md) — host-side tmux config installation
- [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) — current quirks log
