# devpod — DevPod workspace orchestrator (`dvw`) and helpers

Host-side scripts and operational notes for running DevPod workspaces on `vossisrv`. The main entrypoint is `dvw`, a bash CLI that replaces the DevPod Desktop app's missing cross-machine workspace sync via a catalog file kept in sync through the existing rclone Dropbox mount.

## Why dvw exists

The DevPod Desktop app stores workspace metadata locally per machine. Switching from Mint to WSL means the second machine sees an empty workspace list, even though all the containers are still running on `vossisrv`. `dvw` fixes that by writing every workspace to a shared JSON catalog at `~/Dropbox-remote/dvw/catalog.json`. Any client that has the rclone mount and the dvw script sees the same workspaces and can connect, start, stop, and create new ones.

## Folder layout

| Path | Purpose |
|------|---------|
| `dvw` | CLI entrypoint (sources `lib/*`) |
| `lib/` | catalog, ssh-sync, connect, wizard, commands, UI |
| `systemd/rclone-dropbox.service` | rclone mount as a systemd user unit |
| `dvw-install.sh` | idempotent bootstrap for Mint and WSL |
| `tests/bats/` | bats test suite for catalog logic |
| `blueprint/` | `devcontainer.json` template |
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
| `dvw blueprint [path]` | drop `blueprint/devcontainer.json` into `<path>/.devcontainer/` so `dvw new` can build a proper workspace from that repo |
| `dvw rm <id>` | delete workspace + remove from catalog (confirm if running) |
| `dvw stop <id>` | `devpod stop` |
| `dvw start <id>` | `devpod up` with the workspace's saved IDE |
| `dvw status` | one-line per workspace: id, repo@branch, ide, running?, last used |
| `dvw doctor` | health check: rclone mount, catalog, ssh-sync, devpod, gum, orphans |

## Install on Mint

```bash
git clone <this repo>
cd devMachine
./devpod/dvw-install.sh
dvw doctor
```

The installer is idempotent — re-run it any time. It will install missing apt packages (jq, fuse3, gum, devpod), pull rclone ≥ 1.65 from the upstream installer (replacing apt's old 1.60.1 if present, since noble's stale rclone has known FUSE/Dropbox stability bugs), set up the systemd rclone-dropbox unit, wire up the SSH config sync, and symlink `dvw` into `~/.local/bin`.

## Install on WSL Ubuntu

```bash
git clone <this repo>
cd devMachine
./devpod/dvw-install.sh
```

**First run on a fresh WSL** will detect that systemd is not enabled, write `/etc/wsl.conf`, and stop with this message:
> systemd is now enabled, but WSL must be restarted. From Windows PowerShell: `wsl --shutdown`. Then re-open WSL and re-run.

After `wsl --shutdown` and reopening WSL, re-run `./devpod/dvw-install.sh`. It will continue from where it left off (configure rclone, drop the systemd unit, install dvw).

If you do not yet have an rclone Dropbox remote configured, the installer will instruct you to run `rclone config` interactively (one-time per machine).

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

### Pull the latest `install.sh` into a running workspace

```bash
ssh -t <workspace>.devpod 'bash -lc "cd /tmp/aicoding && git pull origin main && bash install.sh"'
```

## Catalog location and sync

- Catalog: `~/Dropbox-remote/dvw/catalog.json` — single JSON file, hand-editable.
- Sync: rclone mount of the `dropbox:` remote, running as a systemd user service. Poll interval 30s; staleness is bounded by that.
- Conflicts: ignored by design (single user, two machines, no concurrent writes). `dvw doctor` flags any `*conflicted copy*` files Dropbox might create.
- Mount hardening (`systemd/rclone-dropbox.service`): `ExecStartPre` cleans stale FUSE handles + ensures the mountpoint dir exists; `Restart=always` (was `on-failure`) catches clean exits and FUSE wedges; `--vfs-cache-mode writes` (was `minimal`) for resilience under intermittent connectivity; `Environment=PATH=/usr/local/bin:/usr/bin:/bin` + `ExecStart=/usr/bin/env rclone …` so the unit works whether rclone is at the apt path or the upstream path.

## SSH config sync

Same Dropbox-backed pattern as the catalog. A blueprint at
`~/Dropbox-remote/dvw/ssh-blueprint.conf` is the single source of truth.
On every `dvw` invocation, `lib/ssh-sync.sh` refreshes the local copy at
`~/.ssh/dvw.conf` if the blueprint is newer (mtime check). Your real
`~/.ssh/config` is untouched apart from one `Include "dvw.conf"` line
that the installer prepends at the top of the file.

The seeded blueprint contains a `Host *.devpod` block with
`ControlMaster auto` for SSH multiplexing — first connect to a workspace
takes ~2s, every subsequent ssh to the same host within 10 minutes is
near-instant (~5ms; verified: 400× speedup on second connect).

To roll out a config change to all machines, edit
`~/Dropbox-remote/dvw/ssh-blueprint.conf` on either box. Within ~30s the
other machine sees the new blueprint and the next `dvw` call refreshes
its local copy.

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

## What to do if rclone mount dies

```bash
systemctl --user status rclone-dropbox
systemctl --user restart rclone-dropbox
```

dvw will refuse to run when the mount is down rather than silently using a stale local copy. If the catalog directory itself looks fine but you suspect bad cached state, `fusermount -u ~/Dropbox-remote && systemctl --user restart rclone-dropbox`.

If the unit is `inactive (dead)` after every reboot (not `failed`, just never started) and a `systemctl --user daemon-reload` "fixes" it — that's the ecryptfs+linger ordering bug ([LP #1746527](https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/1746527) / [#1734290](https://bugs.launchpad.net/ecryptfs/+bug/1734290)). With `/home/$USER` on ecryptfs and `Linger=yes`, the user systemd manager starts at boot before PAM decrypts home, so `~/.config/systemd/user/default.target.wants/` is invisible. The installer detects this and disables linger; if you re-enabled it manually, run `loginctl disable-linger "$USER"`.

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

## Tests

```bash
./devpod/tests/bats/run.sh
```

Catalog logic is covered by bats. Wizard and TUI behavior is verified manually.

## See also

- [`blueprint/README.md`](blueprint/README.md) — `devcontainer.json` template
- [`tmux/README.md`](tmux/README.md) — host-side tmux config installation
- [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) — current quirks log
