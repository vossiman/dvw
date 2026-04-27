# devpod — DevPod helpers and operations

Host-side scripts, configs, and operational notes for running DevPod workspaces on vossisrv with Cursor as the local IDE.

## Folder layout

| Path | Purpose |
|------|---------|
| `dvw` | Workspace picker + tmux attach helper |
| `blueprint/` | Copy-paste `devcontainer.json` template + usage docs |
| `tmux/` | Host-side tmux configs (`tmux-local.conf`) and diagnostics |
| `cursor-shim.sh`, `install-cursor-shim.sh` | Cursor AppImage triple-launch workaround |
| `KNOWN_ISSUES.md` | Catalog of current rough edges and their workarounds |

## Daily workflow

### Connect to a workspace and attach tmux

```bash
dvw                  # auto-picks if only one workspace, otherwise fzf/numbered menu
dvw <workspace-id>   # direct
dvw -l               # list and exit
```

`dvw` SSHes into `<workspace>.devpod` (the alias DevPod creates per workspace), starts the container if it's stopped, and runs `tmux new -A -s work` — attaches to a session named `work` if it exists, creates it if not. Detach with `Ctrl-b d`; re-`dvw` to come back to the same session.

### Spin up a new workspace

```bash
devpod up git@github.com:<owner>/<repo>.git@<branch> --ide cursor
```

**Always use SSH URLs (`git@…`), not HTTPS** — private repos fail with HTTPS because vossisrv has no GitHub credentials in its remote-clone path.

The branch is appended via `@<branch>` in the URL (e.g. `git@github.com:foo/bar.git@devpod`). DevPod's `--branch` flag does not exist.

### Pull the latest `install.sh` into a running workspace

```bash
ssh -t <workspace>.devpod 'bash -lc "cd /tmp/aicoding && git pull origin main && bash install.sh"'
```

Refreshes Claude Code, opencode, MCPs, plugins, hooks, skills. Does **not** apply changes to mounts or lifecycle hooks (those are baked at container create time and need a recreate to update).

### Recreate a workspace cleanly

If you've changed mounts, postCreateCommand, or the base image — or you just want a fresh slate:

```bash
devpod delete <workspace-id>

# Interactive sudo: type your password when prompted.
# `-t` allocates a TTY so the sudo prompt actually appears on your terminal.
ssh -t vossi@vossisrv 'sudo rm -rf /home/vossi/.devpod/agent/contexts/default/workspaces/<workspace-id>'

devpod up git@github.com:<owner>/<repo>.git@<branch> --ide cursor
```

**Why the manual `sudo rm`:** if the project's compose stack writes through bind mounts (e.g. `eval-api/data/`, `postgres/data/`, `minio_data/`), Docker-in-docker creates those files as root. DevPod's agent runs as `vossi`, can't `rm` them, silently reports "successfully deleted workspace" while leaving root-owned junk behind. The next `devpod up` finds the half-clone, can't write a fresh git checkout over it, and falls back to a generic `base:ubuntu` image with no `devcontainer.json` detected — symptom is a workspace with `eval-api/` and a 55-byte `.devcontainer.json` and nothing else.

The `sudo rm -rf` requires interactive auth. Don't try to script it past the password prompt.

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
|------|-------|
| `postCreateCommand` | Once when container is first built. Never again. |
| `postStartCommand` | Every container start: initial create-time start AND after `devpod stop` → `devpod up`, vossisrv reboots, etc. **NOT on simple reattach when the container is already running.** |

Editing `.devcontainer/devcontainer.json` after a container exists doesn't update the in-place container — DevPod baked the old hooks at creation. Recreate to apply new hooks.

## See also

- [`blueprint/README.md`](blueprint/README.md) — exact `devcontainer.json` template + how to drop it into a project
- [`tmux/README.md`](tmux/README.md) — host-side tmux config installation
- [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) — current quirks log
