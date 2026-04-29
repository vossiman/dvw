# Known issues — DevPod + Cursor + Claude/opencode

Running log of rough edges in the current setup, why they exist, and how we work around them. Update as we fix things or move on.

## Base image (`mcr.microsoft.com/devcontainers/universal:6`, Ubuntu 24.04 noble)

This was previously `universal:2` (Ubuntu 20.04 focal). Most workarounds below originated against `:2` — many can probably be dropped on `:6`. **Verify on first fresh spawn against the new image and prune `install.sh` accordingly.**

### Issues that lived on `:2` — re-check on `:6`

- **`nvs` / `nvsudo` syntax errors** in non-interactive shells. Root cause: `mcr.microsoft.com/devcontainers/universal:6` ships `/etc/profile` sourcing `/usr/local/nvs/nvs.sh`, which `export -f`s multi-line `nvs`/`nvsudo` bash functions. Some layer in the devpod / `docker exec` / `su` chain truncates the multi-line function bodies to one line during env propagation — known long-standing devcontainer/VSCode bug ([vscode#3928](https://github.com/Microsoft/vscode/issues/3928), [vscode-remote-release#9457](https://github.com/microsoft/vscode-remote-release/issues/9457)). Every child bash that inherits the truncated env errors on import with `syntax error: unexpected end of file`.

  **Failed-import env vars can't be removed from inside bash.** `unset -f nvs` is a no-op because the import failed and the function was never defined. `unset 'BASH_FUNC_nvs%%'` silently does nothing because `%%` makes the name an invalid identifier — bash refuses. (Earlier versions of `install.sh` and `postStartCommand` used these and quietly didn't work.) The only mechanism that actually strips them is `env -u` at the process boundary, before bash starts.

  **Fixed via three layers:**
  1. `containerEnv` overrides the (initially clean) container Config.Env with valid no-op function bodies, so any shell that inherits Config.Env imports cleanly.
  2. `install.sh` re-execs itself via `env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' bash "$0" "$@"` at the very top, guarded by `_AICODINGSETUP_NVS_STRIPPED=1`. This stops broken env from cascading into install.sh's children (apt, bw-AICode installer, etc.).
  3. `postCreateCommand` and each `postStartCommand` entry in the blueprint are wrapped in `env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' bash -c '...'`, so devpod's outer hook bash starts with the broken vars already removed.
  4. (Defense-in-depth) `install.sh` also patches `/etc/profile` to `unset -f nvs nvsudo` after `nvs.sh` runs, so login shells that source `/etc/profile` after the import step still end up with clean env for their children.

  Residual: the very first `Run command : … bash install.sh` may still emit one batch of errors during devpod's outermost bash startup, before our `env -u` wrappers can take effect — because devpod itself is what spawns that bash. Every other hook in the recreate and every later `up` should be completely clean. The `pull-git-lfs-artifacts.sh` line is a devpod-internal hook we can't wrap; it's clean once `/etc/profile` is patched.
- **tmux 3.0a too old** — no `display-popup` (3.2+) or `allow-passthrough` (3.3+). Mitigation: `install.sh` builds tmux 3.5a from source. Noble ships ≥3.4, so the build step is probably superfluous on `:6`.
- **`kitty-terminfo` not preinstalled** — `infocmp xterm-kitty` failed, tmux refused to start under kitty SSH. Mitigation: `apt install kitty-terminfo`.
- **Yarn apt source ships a stale GPG key** (`NO_PUBKEY 62D54FD4003F6525`). Mitigation: `drop_broken_apt_sources()` in `install.sh` deletes the offending file. Likely fixed in `:6`.
- **`DEBIAN_FRONTEND=noninteractive` doesn't survive `sudo`** — debconf falls back to Dialog/Readline/Teletype frontends and spams warnings. Mitigation: `$SUDO env DEBIAN_FRONTEND=noninteractive apt-get …`.
- **Node not on non-interactive PATH** — universal:2 exposed Node via NVM only in interactive shells, so `install_mcp_packages` and Playwright skipped silently. Mitigation: `ensure_node` is called early in `auto_install_prereqs`. Noble's image arrangement may differ.

### Things we definitely still need regardless of base image

- **Native Claude Code installer required** — Claude Code enforces `installMethod: "native"` matches binary path `~/.local/bin/claude`. `install.sh` uses `curl -fsSL https://claude.ai/install.sh | bash` (and detects + migrates legacy npm installs).
- **opencode binary path** — `opencode` installer drops at `~/.opencode/bin/opencode`; symlinked into `~/.local/bin/` so non-interactive shells (postStartCommand) find it.
- **`hasCompletedOnboarding` flag** — without it in `~/.claude.json`, Claude Code prompts for login on every session even with valid `.credentials.json`. `install.sh`'s `ensure_claude_onboarding_state()` writes it.

## Container lifecycle

- **`devpod delete` (and therefore `dvw rm`) leaves root-owned files behind** when the project's compose stack writes through bind mounts (e.g. `eval-api/data/`, `postgres/data/`, `minio_data/`). DevPod's agent runs as `vossi`, can't `rm` root-owned content, silently reports "successful delete" — next `up` finds the half-clone and falls back to a generic `base:ubuntu` image with no devcontainer.json detected. **Workaround:** after `dvw rm <name>` (or raw `devpod delete`), run `ssh -t vossi@vossisrv 'sudo rm -rf /home/vossi/.devpod/agent/contexts/default/workspaces/<name>'`. The `-t` is required so sudo can prompt for the password. **Real fix:** dataEnv-side switch from bind mounts to Docker named volumes.
- **Lifecycle hooks bake at create time** — editing `.devcontainer/devcontainer.json` on the branch and `devpod up`'ing an existing workspace doesn't apply the new hooks. `--recreate` (or delete + up + the sudo-rm above) is required. Affects `mounts`, `postCreateCommand`, `postStartCommand`.
- ~~**Outer DevPod shell `nvs/nvsudo` warnings**~~ — *Fixed.* `containerEnv` in blueprint overrides the broken `BASH_FUNC_*%%` exports with no-op bodies before any bash starts.
- **`Could not find docker daemon config file` warning** — DevPod nags about `containerd-snapshotter`. Cosmetic; could be silenced by writing `/etc/docker/daemon.json` on vossisrv.

## Cursor (host integration)

- **AppImage triple-launch on `devpod up`** — DevPod fires `cursor` three times (`--list-extensions`, `--install-extension`, `--new-window`); raw AppImage opens a GUI window for each. Mitigation: `~/.local/bin/cursor` shim that auto-extracts the AppImage and points at `squashfs-root/usr/share/cursor/bin/cursor`. Self-healing on Cursor updates (re-extracts when the AppImage mtime changes).

## Claude Code / opencode auth

- **Both `.credentials.json` and `~/.claude.json`** are needed for Claude Code to skip onboarding in containers. Bind-mount the whole `~/.claude/` directory (writes propagate back to vossisrv on token refresh); `install.sh` writes the `hasCompletedOnboarding` flag.
- **opencode auth** lives in `~/.local/share/opencode/auth.json`. Bind-mounted from vossisrv so `opencode auth login` once persists across all containers.
- **HTTP MCPs (`logfire`, `claude.ai Google Drive`, etc.)** — can't be authed by `install.sh`; require interactive browser OAuth via `claude` → `/mcp` → select → click. Auth state lands in `~/.claude/`, persists via the bind mount.
- **Project-scope MCPs in `.mcp.json` mask user-scope MCPs** with the same name. A broken project entry (e.g. unprefixed Docker image like `context7-mcp` that doesn't exist on Docker Hub) hides a working user-scope one. Delete the bad project entry to unmask.
- **`context7` plugin doesn't reliably surface its MCP** — `install.sh` registers it explicitly at user scope via `claude mcp add context7 -s user -- npx -y @upstash/context7-mcp`.

## Docker-based project MCPs

- **`mcp/sqlite` and similar** require the image to be present in the dev container's Docker daemon, plus any bind-mounted paths (e.g. `eval-api/data/eval_results.db`) to actually exist on disk. Generated artifacts won't be there in a fresh container — these MCPs report `failed` until project-side bootstrap creates them.

## SSH / terminal

- **Locale forwarding warnings** — host SSH forwards `LC_*=de_AT.UTF-8`, container only has `en_US.UTF-8` and `C.UTF-8` generated. Mitigation: `install.sh` runs `locale-gen de_AT.UTF-8 en_US.UTF-8` (via `ensure_locales`).
- **Non-interactive SSH PATH** — `ssh host 'cmd'` doesn't source rc files, so nvm/Node-managed binaries are missing. Mitigation: `dvw` uses `bash -lc` to force a login shell.

## Open questions / future work

- Switch dataEnv's compose to named volumes so `devpod delete` works without sudo dance.
- Drop tmux-from-source build step if `:6` ships a recent enough tmux.
- Drop yarn-source-cleanup, kitty-terminfo apt step if `:6` doesn't ship the broken yarn list and includes the terminfo.
- ~~Strip the `BASH_FUNC_*` workarounds if `:6` doesn't have the broken NVS exports.~~ *Resolved differently* — `:6` still has them; blueprint now overrides via `containerEnv`. `install.sh` strip stays as defense-in-depth.
