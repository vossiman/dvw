# Known issues — DevPod + Cursor + Claude/opencode

Running log of rough edges in the current setup, why they exist, and how we work around them. Update as we fix things or move on.

**Status legend:**
- 🟢 **MITIGATED** — countermeasure deployed in code (install.sh / blueprint / dvw / cursor-shim). Documented for future debugging or in case the fix regresses.
- 🟢 **ACCEPTED** — known behavior we've decided to live with. No fix planned; documented so we don't re-litigate it.
- 🟡 **WORKAROUND** — manual step required at the right moment; no automated fix in place.
- 🔴 **OPEN** — no countermeasure; lives with us until the upstream fixes itself or we redesign.

## Base image (`mcr.microsoft.com/devcontainers/universal:6`, Ubuntu 24.04 noble)

This was previously `universal:2` (Ubuntu 20.04 focal). Most workarounds below originated against `:2` — many can probably be dropped on `:6`. **Verify on first fresh spawn against the new image and prune `install.sh` accordingly.**

### Issues that lived on `:2` — re-check on `:6`

- 🟢 **MITIGATED — `nvs` / `nvsudo` syntax errors** in non-interactive shells. Root cause: `mcr.microsoft.com/devcontainers/universal:6` ships `/etc/profile` sourcing `/usr/local/nvs/nvs.sh`, which `export -f`s multi-line `nvs`/`nvsudo` bash functions. Some layer in the devpod / `docker exec` / `su` chain truncates the multi-line function bodies to one line during env propagation — known long-standing devcontainer/VSCode bug ([vscode#3928](https://github.com/Microsoft/vscode/issues/3928), [vscode-remote-release#9457](https://github.com/microsoft/vscode-remote-release/issues/9457)). Every child bash that inherits the truncated env errors on import with `syntax error: unexpected end of file`.

  **Failed-import env vars can't be removed from inside bash.** `unset -f nvs` is a no-op because the import failed and the function was never defined. `unset 'BASH_FUNC_nvs%%'` silently does nothing because `%%` makes the name an invalid identifier — bash refuses. (Earlier versions of `install.sh` and `postStartCommand` used these and quietly didn't work.) The only mechanism that actually strips them is `env -u` at the process boundary, before bash starts.

  **Fixed via three layers:**
  1. `containerEnv` overrides the container Config.Env with valid no-op function bodies, so the first bash devpod spawns inherits clean env.
  2. `install.sh` re-execs itself via `env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' bash "$0" "$@"` at the very top, guarded by `_AICODINGSETUP_NVS_STRIPPED=1`. `update.sh` (curled by `postStartCommand`) does the same self-reexec under `_NVS_STRIPPED=1`. This stops broken env from cascading into either script's children.
  3. (Defense-in-depth) `install.sh` patches `/etc/profile` to `unset -f nvs nvsudo` and unset their `BASH_FUNC_*%%` exports after `nvs.sh` runs, so login shells that source `/etc/profile` after the import step still end up with clean env for their children.
- 🟢 **MITIGATED — tmux 3.0a too old** — no `display-popup` (3.2+) or `allow-passthrough` (3.3+). `install.sh` builds tmux 3.5a from source. Noble ships ≥3.4, so the build step is probably superfluous on `:6`.
- 🟢 **MITIGATED — `kitty-terminfo` not preinstalled** — `infocmp xterm-kitty` failed, tmux refused to start under kitty SSH. `install.sh` runs `apt install kitty-terminfo` if the terminfo file is missing.
- 🟢 **MITIGATED — Yarn apt source ships a stale GPG key** (`NO_PUBKEY 62D54FD4003F6525`). `drop_broken_apt_sources()` in `install.sh` deletes the offending file. Likely fixed in `:6`.
- 🟢 **MITIGATED — `DEBIAN_FRONTEND=noninteractive` doesn't survive `sudo`** — debconf falls back to Dialog/Readline/Teletype frontends and spams warnings. `install.sh` uses `$SUDO env DEBIAN_FRONTEND=noninteractive apt-get …`.
- 🟢 **MITIGATED — Node not on non-interactive PATH** — universal:2 exposed Node via NVM only in interactive shells, so `install_mcp_packages` and Playwright skipped silently. `ensure_node` is called early in `auto_install_prereqs`. Noble's image arrangement may differ.

### Things we definitely still need regardless of base image

- 🟢 **MITIGATED — Native Claude Code installer required** — Claude Code enforces `installMethod: "native"` matches binary path `~/.local/bin/claude`. `install.sh` uses `curl -fsSL https://claude.ai/install.sh | bash` (and detects + migrates legacy npm installs).
- 🟢 **MITIGATED — opencode binary path** — `opencode` installer drops at `~/.opencode/bin/opencode`; `install.sh` symlinks it into `~/.local/bin/` so non-interactive shells (postStartCommand) find it.
- 🟢 **MITIGATED — `hasCompletedOnboarding` flag** — without it in `~/.claude.json`, Claude Code prompts for login on every session even with valid `.credentials.json`. `install.sh`'s `ensure_claude_onboarding_state()` writes it.

## Container lifecycle

- 🟢 **MITIGATED — `devpod delete` (and therefore `dvw rm`) leaves root-owned files behind** when a project's compose stack writes through bind mounts (e.g. `eval-api/data/`, `postgres/data/`, `minio_data/`). Postgres/MinIO images run as their hardcoded internal users (uid 999 etc.), Linux bind mounts pass UIDs through directly, so files land on vossisrv as root. DevPod's agent runs as `vossi`, can't `rm` root-owned content, silently reports "successful delete" — next `up` finds the half-clone and falls back to a generic `base:ubuntu` image with no devcontainer.json detected.

  **Fix:** every project compose stack uses Docker **named volumes** for data dirs instead of bind mounts. Docker manages the volume lifecycle; `docker compose down -v` cleans them and `devpod delete` no longer races with root-owned host files. Migration of existing repos is in progress — any repo still using bind-mounted data dirs is grandfathered until converted.

  Other approaches we considered and rejected: `user: "${UID}:${GID}"` per-service breaks postgres/minio (hardcoded uid); Docker `userns-remap` in `/etc/docker/daemon.json` is daemon-wide and forces re-pulling every image; custom Dockerfile UID rebuilds require forking each upstream image.

  **Emergency cleanup** (only for legacy bind-mounted stacks not yet migrated): `ssh -t vossi@vossisrv 'sudo rm -rf /home/vossi/.devpod/agent/contexts/default/workspaces/<name>'`. The `-t` is required so sudo can prompt for the password.

  References: [loft-sh/devpod#1941](https://github.com/loft-sh/devpod/issues/1941), [loft-sh/devpod#1953](https://github.com/loft-sh/devpod/issues/1953), [loft-sh/devpod#1879](https://github.com/loft-sh/devpod/issues/1879).
- 🟢 **ACCEPTED — Lifecycle hooks bake at create time** — editing `.devcontainer/devcontainer.json` on the branch and `devpod up`'ing an existing workspace doesn't apply the new hooks. `--recreate` (or delete + up + the sudo-rm above) is required. Affects `mounts`, `postCreateCommand`, `postStartCommand`. Inherent DevPod behavior; we live with it.
- 🟢 **ACCEPTED — `Could not find docker daemon config file` warning** — Misleading message. DevPod's `configureDockerDaemon()` (in `cmd/agent/workspace/up.go`) tries to enable its registry-cache feature by, in order: (1) writing `~/.config/docker/daemon.json` if rootless docker is detected, (2) falling back to writing `/etc/docker/daemon.json` directly, (3) `pkill -HUP dockerd` to reload. In our setup (rootful docker on vossisrv, agent runs as `vossi`), all three steps fail — vossi can't write `/etc/docker/` and can't signal the root-owned `dockerd` — so the warning fires every `up`. **Pre-creating the file (empty or otherwise) doesn't help**: DevPod tries to *overwrite* it with `{"features":{"containerd-snapshotter":true}}`, and even if that write succeeded, the `pkill -HUP` step would still fail and trigger the same warning. Real fixes require either rootless docker (DevPod's happy path) or patching/waiting on upstream to gate the warning on actually using registry cache. We don't use registry cache → cosmetic noise we live with.
- 🟢 **MITIGATED — `devpod up` on a running container can wipe `content/` and leave a stale bind mount** — Confirmed 2026-05-08 after losing uncommitted source on `financepdfs-git-main`. `devpod up` (verified with `--ide cursor`, suspected for other modes) on a workspace whose container is *already running* re-synthesizes the agent-side workspace dir on the provider host: `rm -rf content/` + sparse re-clone of just `.devcontainer/`, **without recreating the container**. The container's bind mount keeps pointing at the old `content/` inode, which is now an unlinked zombie kept alive only by the mount.

  **Symptoms inside the container:**
  - `readlink /proc/<pid>/cwd` → `/workspaces/<id> (deleted)` — kernel marker.
  - `stat /workspaces/<id>` → `Links: 0`.
  - `/proc/self/mountinfo` → mount source path includes `//deleted`.
  - Anything calling `getcwd(2)` errors with ENOENT. Cursor's node fatals on boot (`Error: ENOENT: no such file or directory, uv_cwd`). **Bash tolerates** the dead cwd (prints `shell-init: error retrieving current directory` but keeps running), so SSH+tmux paths kept working — which is why the failure was invisible until Cursor refused to connect.

  **What's lost:** uncommitted source in `/workspaces/<id>` and the entire local `.git` (so any local-only commits, branches, stashes). Bind-mounted home dirs (`~/.claude`, `~/.aicodingsetup`, `~/.local/share/opencode`) are unaffected — they're separate mounts from `vossisrv:/home/vossi/devpod/...`.

  **Trigger that bit us:** `dvw <id> --both` calls `_connect_cursor`, which previously ran `devpod up --ide cursor` unconditionally on every connect. The container was running on its original bind-mount inode; `devpod up` wiped + recreated host `content/` (new inode), leaving the container's bind mount pointing at the now-unlinked old inode.

  **Four layers of defense in dvw:**
  1. **Probe before `devpod up` in the cursor path.** `_connect_cursor` (in `lib/connect.sh`) probes via `_dvw_workspace_health`: SSH in, `cd /workspaces/<id>`, check `readlink /proc/self/cwd` for the `(deleted)` marker. Outcomes: `alive` → skip `devpod up` entirely (the `*.devpod` SSH bridge already routes Cursor; devpod CLI doesn't need to be involved); `stale` → refuse with a `dvw recreate <id>` hint; `cold` → fall through to `devpod up`. Commit `1e1fe04`.
  2. **Provider-level safety wrapper for all cold-path `devpod up` callers.** `_dvw_safe_devpod_up` (in `lib/connect.sh`) wraps every dvw-internal `devpod up` caller — `_connect_ssh`, `_connect_cursor` cold-path, `cmd_blueprint`, and (as of the 2026-05 provider-probe refactor) `cmd_start` too. Before running `devpod up`, it asks the provider host directly whether a container for this workspace exists. **Additionally**, the cold-path callers themselves now check `_dvw_provider_has_container` before falling into the wrapper at all — if the container is confirmed to exist, the cold path skips `devpod up` entirely and proceeds to open the workspace directly (Cursor handles its own ssh-remote retries; SSH mode uses long-timeout `exec ssh`). The wrapper's interactive Yes/No prompt was a wipe-risk escape hatch on slow links where the 3s/5s BatchMode alias probe times out but the container is fine — removing the prompt for confirmed-existing containers prevents accidental Yes-clicks. Commits `6086b95`, then the provider-probe rewrite.
  3. **Visibility — verified status from the provider, not inferred locally.** `dvw status`, `dvw doctor`, and the picker compute state from a single SSH probe to the provider host (`_dvw_load_probe` in `lib/connect.sh`), which lists containers, reads `/proc/1/cwd` for the `(deleted)` marker on running ones, and joins to catalog entries by uid. Five user-visible states: `● running`, `⚠ stale`, `○ stopped`, `✗ absent`, `? unreachable`. Crucially, **`? unreachable` is distinct from `○ stopped`** — it means "this machine can't ask the provider," not "the container is down." That distinction is what made the symptom show up: the previous N-fragile-per-workspace-alias probe conflated the two, and a PC with a momentary SSH-config / agent-loading issue would render every workspace as stopped while they were all running. Commits `3ffc574`, `a9af7ea`, then the provider-probe rewrite.
  4. **`--dry-run` flag.** Every mutating dvw command (`dvw <id>`, `start`, `recreate`, `rm`, `stop`) accepts `--dry-run` and prints the underlying `devpod ...` / `docker ...` invocations without executing them. Lets you see exactly what's about to happen before committing.

  **Recovery for an already-stale workspace:** `dvw recreate <id>` (or `docker restart <name>` on the provider, then re-clone the source). Restart reattaches bind mounts to whatever the source path resolves to *now*. Data already gone is gone — these only fix the bind mount and let new connections succeed.

  **Out of scope for the wrapper:** `cmd_new` has no prior container by definition. Manual `devpod up` invocations outside dvw can still hit this. Upstream root cause (why `devpod up` is destructive on a running container) was not investigated; the wrapper sidesteps the question rather than answering it.

- 🟢 **MITIGATED — uid drift between client and agent workspace.json** — Confirmed 2026-05-11 after PC's `dvw <id> --ssh` repeatedly failed with `su: user codespace does not exist` inside the container. The agent's container was a recent build with the codespace user; the PC was being bridged to an *orphan* container from a previous incarnation of the workspace that was missing it. The PC's local uid had drifted from the agent's.

  **The two workspace.json layouts.** DevPod stores per-workspace state in two different shapes that don't interoperate:
  - **Client-side** (`~/.devpod/contexts/<ctx>/workspaces/<id>/workspace.json` on each machine): `{ "id": ..., "uid": <uid>, "provider": { "options": { "HOST": ... } }, ... }` — fields at top level.
  - **Agent-side** (`~/.devpod/agent/contexts/<ctx>/workspaces/<id>/workspace.json` on the provider host): `{ "workspace": { "uid": <uid>, "provider": ... }, ... }` — fields nested under `.workspace`.

  Confusing both layouts as one was the root of three latent bugs in dvw that compounded the user-visible failure:
  - `_dvw_reconcile_uid` read `.workspace.uid` from the local (client-side) file → always got empty → short-circuit gate `[[ -z "$cat_uid" ]] && return 0` made the function a near-no-op for legacy entries with no catalog uid.
  - `_dvw_rewrite_local_uid` wrote `.workspace.uid` to the client-side file → silently created a phantom nested field while the real top-level `.uid` stayed stale.
  - `catalog_workspace_set_devpod_state` read `.workspace.uid` from the client-side file → catalog's convenience `.uid` field never got populated from any client snapshot.

  Together: reconcile *looked* like it worked, fired rarely, and even when it fired it rewrote the wrong field. So PC's local uid (`default-da-89c70`, pointing at a previous-incarnation container) never got aligned to the agent's current uid (`default-da-59292`, pointing at the live container with the codespace user). `devpod ssh --stdio` from PC ended up bridging to the orphan, `su codespace` failed there.

  **Fix (commit `4aab291`):** all three paths now use the correct layout for the file they're reading/writing. `_dvw_reconcile_uid` always runs (no more gating on empty `cat_uid`), uses the **agent as authoritative** (the agent's workspace.json is what DevPod's own agent uses to find containers, so client/catalog drift is always resolved by aligning to the agent), and atomically rewrites client + catalog. Voting between local/catalog/remote candidates was removed — over-engineered for the actual problem.

  **Provider-side probe was also rewritten (commit `f9b8675`)** to do the id↔uid↔state join server-side rather than depending on the catalog snapshot for the uid. The server reads its own `~/.devpod/agent/contexts/default/workspaces/<id>/workspace.json` for the uid, joins with `docker ps -a` labels, and returns `<id> <state>` lines. Client never needs to know any uid for status — the agent has both halves and tells us the answer. This makes the probe robust to every client-side missing-data case (`uid: null`, missing snapshot, fresh machine, etc.).

  **Cold-branch policy in connect paths (commit `e2a42d6`)** — `_connect_ssh`, `_connect_cursor`, `cmd_blueprint`: if the per-workspace alias SSH probe fails but `_dvw_provider_has_container` confirms a container exists, the cold branch now skips `devpod up` entirely and opens directly. Cursor handles its own ssh-remote retries; SSH mode uses `exec ssh` with default (long) timeouts. The `_dvw_safe_devpod_up` interactive Yes/No prompt — a wipe-risk escape hatch — is no longer reachable in normal operation. Alias-probe `ConnectTimeout` was also bumped from 3s to 5s to reduce false-cold reports on slow links.

  **Self-healing behavior:** on every `dvw <id>` / `dvw start <id>` / `dvw recreate <id>` / `dvw blueprint`, reconcile runs first. Drift gets detected and rewritten before any SSH chain that depends on the uid. The catalog also gets updated, so other machines pick up the alignment on their next pull. Pre-existing catalog entries that never had `.devpod_state` populated converge to a healthy state the first time any machine connects to them.

- 🟢 **MITIGATED — orphan containers from previous workspace incarnations** — Each `devpod up --recreate` (or manual `devpod up` after editing devcontainer config) creates a new container with a new uid, leaving the previous container intact under its old uid. Over time the provider accumulates "orphans" — devpod-labelled containers whose uid isn't claimed by any current `~/.devpod/agent/contexts/default/workspaces/<id>/workspace.json`.

  Orphans aren't automatically harmful — they sit on the provider consuming disk — but they bit the user once when the PC's stale client uid pointed at an orphan that didn't have the codespace user (see preceding entry).

  **Detection (Tier 1, in `dvw doctor`):** the provider-side probe emits per orphan: uid, container name, state, and `/workspaces/<id>` bind-mount status (`alive` / `deleted` / `nomount`). Surfaced in `dvw doctor` as one warning line per orphan. Bind-mount `deleted` means the host source path is gone (the stale-bind-mount fingerprint from item above) — data unrecoverable from that container. `alive` means the bind-mount source is still on disk and may contain uncommitted edits or unpushed commits.

  **Audit (Tier 2, via the top menu):** when orphans exist, the `dvw` top menu surfaces an "⚠ Audit orphan containers (N)" entry. Choosing it triggers `cmd_orphans_audit` which does one ssh per provider host bundling all that host's orphans. Per orphan it reports:
  - For running orphans: `docker exec` into the container and run `git status / git rev-list @{u}.. / git stash list` inside `/workspaces/<id>`.
  - For exited orphans: same git read-only commands against the bind-mount source path on the provider host directly (no docker exec — the container is stopped).

  Each orphan gets a per-line verdict:
  - `✓ clean` — no uncommitted/unpushed/stashed git state detected
  - `⚠ has work` — copy out before removing
  - `✗ unrecoverable` — bind mount is stale or source path is missing on host
  - `? could not inspect` — docker exec timed out, no `.git`, or no upstream

  **Removal stays manual** — `dvw` never executes `docker rm` itself. The audit footer prints the template `ssh <host> 'docker rm -f <container-name>'`; the user types it after deciding the audit shows nothing worth keeping.

  **Layout notes for future hackers:**
  - The probe uses TAB-separated docker `--format` output **plus** `--filter "label=dev.containers.id"` to scope to devpod-labelled containers only. Earlier attempts to parse unlabelled-container output with bash `read` failed because `IFS=$'\t'` is treated as whitespace-only IFS — bash strips leading IFS chars, so an empty first field collapses and downstream fields shift into the wrong slots. Filtering at the docker level sidesteps the parsing trap entirely.
  - Orphan info is keyed by uid in `DVW_PROBE_ORPHAN_INFO` (associative array in `connect.sh`). The host alias is prepended client-side (the server-side script doesn't know its own SSH alias).

## Cursor (host integration)

- 🟢 **MITIGATED — AppImage triple-launch on `devpod up`** — DevPod fires `cursor` three times (`--list-extensions`, `--install-extension`, `--new-window`); raw AppImage opens a GUI window for each. `~/.local/bin/cursor` shim auto-extracts the AppImage and points at `squashfs-root/usr/share/cursor/bin/cursor`. Self-healing on Cursor updates (re-extracts when the AppImage mtime changes).

## Claude Code / opencode auth

- 🟢 **MITIGATED — Both `.credentials.json` and `~/.claude.json`** are needed for Claude Code to skip onboarding in containers. Blueprint bind-mounts the whole `~/.claude/` directory (writes propagate back to vossisrv on token refresh); `install.sh` writes the `hasCompletedOnboarding` flag.
- 🟢 **MITIGATED — opencode auth** lives in `~/.local/share/opencode/auth.json`. Blueprint bind-mounts it from vossisrv so `opencode auth login` once persists across all containers.
- 🟡 **WORKAROUND — HTTP MCPs (`logfire`, `claude.ai Google Drive`, etc.)** — can't be authed by `install.sh`; require interactive browser OAuth via `claude` → `/mcp` → select → click. Auth state lands in `~/.claude/`, persists via the bind mount thereafter.
- 🟡 **WORKAROUND — Project-scope MCPs in `.mcp.json` mask user-scope MCPs** with the same name. A broken project entry (e.g. unprefixed Docker image like `context7-mcp` that doesn't exist on Docker Hub) hides a working user-scope one. Delete the bad project entry to unmask.
- 🟢 **MITIGATED — `context7` plugin doesn't reliably surface its MCP** — `install.sh` registers it explicitly at user scope via `claude mcp add context7 -s user -- npx -y @upstash/context7-mcp`.

## Docker-based project MCPs

- 🟡 **WORKAROUND — `mcp/sqlite` and similar** require the image to be present in the dev container's Docker daemon, plus any bind-mounted paths (e.g. `eval-api/data/eval_results.db`) to actually exist on disk. Generated artifacts won't be there in a fresh container — these MCPs report `failed` until project-side bootstrap creates them.

## SSH / terminal

- 🟢 **MITIGATED — Locale forwarding warnings** — host SSH forwards `LC_*=de_AT.UTF-8`, container only has `en_US.UTF-8` and `C.UTF-8` generated. `install.sh` runs `locale-gen de_AT.UTF-8 en_US.UTF-8` (via `ensure_locales`).
- 🟢 **MITIGATED — Non-interactive SSH PATH** — `ssh host 'cmd'` doesn't source rc files, so nvm/Node-managed binaries are missing. `dvw` uses `bash -lc` to force a login shell.
- 🟢 **MITIGATED — `Include` directive shadows when nested in a Host block** — OpenSSH propagates the enclosing Host block's `activep` flag into `Include` directives. So `Include "dvw.conf"` placed at the bottom of `~/.ssh/config` (inside the last user-managed Host block) silently ignores its content for the queried hostname; `Host *.devpod` inside the include never matches. `dvw`'s installer (`ssh_sync_init` in `lib/ssh-sync.sh`) prepends the Include line at the very top of `~/.ssh/config`, before any Host block, so `activep=TRUE` carries into the include. `dvw doctor` warns if a stale install left the line at the bottom; `ssh_sync_init` auto-relocates.

## Host-side rclone

- 🟢 **MITIGATED — Ubuntu noble's apt rclone (1.60.1) has FUSE/Dropbox stability bugs** — Long-since fixed in upstream 1.69+. `dvw-install.sh` checks for rclone ≥ 1.65 and otherwise (a) `apt remove`s the dpkg-owned binary, then (b) installs upstream via `curl https://rclone.org/install.sh | sudo bash`. **Order matters:** the upstream installer drops at `/usr/bin/rclone` (NOT `/usr/local/bin/`). If you upstream-install first then `apt remove rclone`, dpkg deletes the upstream binary because it still owns the path. The installer does this in the right order automatically; manual upgrades need to apt-remove first.
- 🟢 **MITIGATED — Mount silently wedges or systemd state goes stale** — Earlier unit had `Restart=on-failure` (only catches non-zero exits), no `ExecStartPre` cleanup, and pinned `/usr/bin/rclone`. Now: `Restart=always`, `ExecStartPre=-/bin/fusermount3 -u` cleans stale FUSE handles, `ExecStartPre=/bin/mkdir -p` ensures the mountpoint dir exists, `--vfs-cache-mode writes` (was `minimal`) handles intermittent network better, and `ExecStart=/usr/bin/env rclone` with `Environment=PATH=…` makes the unit work for both apt and upstream rclone paths.

## Install / update lifecycle

- 🟢 **RESOLVED — silent half-broken environment on rebuild** — Confirmed 2026-05-27 on this workspace: `~/.tmux.conf` (and the other managed files in non-bind-mounted home paths) had silently disappeared after a container rebuild, while the manifest at `~/.aicodingsetup/manifest.json` claimed everything was deployed. Root cause: the `.aicodingsetup` bind-mount persists the manifest across rebuilds, but the container's home tree is otherwise ephemeral — `install.sh`'s old `prereq_only` mode treated "manifest exists" as "files are deployed" and skipped every file deploy, leaving the user to manually run `aicoding-update` to notice. **Fix:** `install.sh` now has a `reconcile` mode (replacing `prereq_only`) that classifies each managed file and auto-restores any that are missing on disk, applies blueprint updates for files the user hasn't touched, and re-merges merge-mode files. Drifted edits and `to_remove` entries are reported but never auto-applied — strictly more conservative than `aicoding-update --yes`. Every run emits an `INSTALL OK  blueprint <sha>  new N  restored R  updated U  merged M  drifted D  to_review T` line; absence of the line means provisioning aborted. ERR trap also added (`INSTALL FAILED  step=<header>  line=N` to stderr). See spec `docs/superpowers/specs/2026-05-28-setup-update-path-overhaul-design.md` and plan `docs/superpowers/plans/2026-05-28-setup-update-path-overhaul.md`. Shipped via `aiCodingBaseSetup` PR #1 (merge `0b60e9f`) and pinned in this repo via the `devpod/aicoding` submodule.

## Open questions / future work

- Drop tmux-from-source build step if `:6` ships a recent enough tmux.
- Drop yarn-source-cleanup, kitty-terminfo apt step if `:6` doesn't ship the broken yarn list and includes the terminfo.
