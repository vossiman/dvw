# DevPod blueprint devcontainer.json

Drop-in `.devcontainer/devcontainer.json` for any project that should come up as a fully-configured AI coding workspace under DevPod (Mint or Win11 client → vossisrv backend).

> **Source of truth:** the canonical generic template lives upstream at [`vossiman/aiCodingBaseSetup/devcontainer.json`](https://github.com/vossiman/aiCodingBaseSetup/blob/main/devcontainer.json). The copy here adds the vossisrv-specific `mounts` (aicodingsetup / claude / opencode / codex / cursor bind paths) on top. When the upstream template changes, sync those changes into this copy and re-attach the mounts.

## How to use

```bash
cd <your-project>
mkdir -p .devcontainer
cp /path/to/dvw/blueprint/devcontainer.json .devcontainer/devcontainer.json
git add .devcontainer/devcontainer.json
git commit -m "Add devcontainer config for DevPod"
git push
```

Then from any client:

```bash
dvw new                                       # preferred: wizard adds to catalog
# or, raw equivalent (skips the catalog):
devpod up <repo-url>@<branch> --ide cursor
```

First spin-up runs `install.sh` from `aiCodingBaseSetup` — installs Claude Code CLI, opencode, Go, Playwright browsers, MCPs, plugins, skills, hooks, and bw-AICode. Subsequent spin-ups reattach in seconds.

## Updating an existing container

`aiCodingBaseSetup` (HEAD ≥ `3a12b41`) tracks every managed file in a manifest at `~/.aicodingsetup/manifest.json` and ships a `aicoding-update` CLI for picking up new blueprint changes without losing local edits.

```bash
aicoding-update --dry-run   # show what would change vs your container
aicoding-update             # interactive: inline diff for drift, single y/N confirm
aicoding-update --yes       # scripted; .bak's anything you drifted before overwriting
```

Behaviour summary:

- **First time** a container hits the new blueprint, `install.sh` runs in **adopt mode** — captures each existing managed file's current hash into the manifest without overwriting. Old hand-edits survive.
- **Subsequent re-runs of `install.sh`** on the same container are **prereq-only** — apt/build steps re-check (idempotent), file deploys are skipped. The script prints `Container already initialized at blueprint <commit>` and points you at `aicoding-update`.
- **For blueprint file changes**, run `aicoding-update`. It refreshes `/tmp/aicoding` from origin, classifies each managed file (`up_to_date` / `will_update` / `drifted_but_aligned` / `drifted_and_updating` / `new_file` / `to_remove` / `restore` / `merge`), shows the summary with inline diffs for the drifted ones, and applies after one confirm. Any file you'd manually changed gets backed up to `<file>.bak.<timestamp>` before being overwritten.
- **Escape hatch:** `bash /tmp/aicoding/install.sh --force-reinstall` deletes the manifest and re-deploys everything from scratch — use only when you want the container reset.

User convention for personal `~/.bashrc.d/` additions: prefix them with anything *other than* `aicoding-` (e.g. `local-myaliases.sh`). The managed block in `~/.bashrc` sources every `.sh` in the directory, so your additions get picked up automatically but `aicoding-update` only touches files matching `aicoding-*`.

Deep dive in `docs/superpowers/specs/2026-05-16-blueprint-sync-design.md` (this repo's spec) and the corresponding plan under `docs/superpowers/plans/`.

## What each line does

- **`image`** — base devcontainer image. Universal:2 is the kitchen sink (~5 GB), works for any language. Swap for leaner if the project is single-language.
- **`remoteUser`** — must match the image's hardcoded user (see table below).
- **`mounts`** — bind **five** directories from vossisrv into the container so secrets and per-CLI auth + config persist across workspaces:
  - `aicodingsetup` → `~/.aicodingsetup/` holds `.secrets.env` (API keys for firecrawl, brave, cloudflare) and `manifest.json` (deploy state, survives rebuilds).
  - `claude` → `~/.claude/` holds `.credentials.json`, `settings.json`, plugins, hooks, skills. Token refreshes write back to vossisrv, so logging in once persists across every container.
  - `opencode` → `~/.local/share/opencode/` holds `auth.json` (provider tokens for Anthropic / OpenAI / Google / etc.). `opencode auth login <provider>` once in any container persists across every other.
  - `codex` → `~/.codex/` holds codex's `auth.json` (ChatGPT sign-in token or API key state) and `config.toml` (codex's MCP declarations, redeployed every rebuild by reconcile).
  - `cursor` → `~/.cursor/` holds cursor-agent credentials and `mcp.json`. The parent dir is bind-mounted because cursor-agent's exact credential filename isn't publicly documented — bind-mounting the dir covers any internal layout.
> **Pinning.** This template runs `install.sh` from a submodule at `devpod/aicoding/`. Downstream projects adopting the template have two choices:
> 1. **Submodule (recommended).** Add `aiCodingBaseSetup` as a submodule and keep the wiring as shown — the submodule ref is your pin.
> 2. **Tagged clone.** Replace `git submodule update --init --recursive && bash devpod/aicoding/install.sh` with `git clone --quiet --branch <tag-or-sha> --depth=1 https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh`. Don't track `main` — that's the bug this template avoids.

- **`postCreateCommand`** — `git submodule update --init --recursive && bash devpod/aicoding/install.sh`. Initializes the `devpod/aicoding/` submodule defensively (no-op if already present) and runs the installer from there. Submodule ref pins the blueprint version; bumping is `git submodule update --remote devpod/aicoding` + a parent commit. The installer detects container mode automatically and auto-installs prerequisites (claude CLI, opencode, Go, Playwright browsers, jq, locales).
- **`postStartCommand`** — `bash devpod/aicoding/update.sh`. Runs on *every* container start (including reattach), not just first build. The script re-execs itself under `env -u` to strip universal:6's broken `BASH_FUNC_nvs%%`/`nvsudo`/`nvm` exports (see KNOWN_ISSUES.md), then runs `claude update` and `opencode upgrade`. Failures emit a visible `WARN:` line and continue (a transient upgrade failure shouldn't block container start). Replaces the previous `curl|bash` from `main` — source is now pinned to the submodule ref, same as `install.sh`.

> **Self-healing rebuilds.** On every rebuild, `install.sh` runs in `reconcile` mode (the manifest persists in the bind-mounted `~/.aicodingsetup/`, so it's always there post-rebuild). Reconcile auto-restores any managed file that's missing on disk, applies blueprint updates for files you haven't edited, and re-merges JSON merge-mode files. It deliberately does **not** auto-resolve drift (files you edited where the blueprint also changed) or auto-remove files no longer in the blueprint inventory — those are reported in the end-of-run summary and stay for `aicoding-update`. Check the postCreate log for the `INSTALL OK  blueprint <sha> ...` line; its absence means provisioning aborted somewhere.

## Image + remoteUser pairing

The two MUST match the image's default user, or mounts land at the wrong path and nothing works.

| Image | `remoteUser` |
|-------|--------------|
| `mcr.microsoft.com/devcontainers/universal:6` | `codespace` |
| `mcr.microsoft.com/devcontainers/universal:2` (focal, legacy) | `codespace` |
| `mcr.microsoft.com/devcontainers/python:3.12-bookworm` | `vscode` |
| `mcr.microsoft.com/devcontainers/base:debian` | `vscode` |
| `mcr.microsoft.com/devcontainers/javascript-node:22` | `node` |
| `ghcr.io/astral-sh/uv:python3.12-bookworm` | `root` |

If you change the image, also update the two mount target paths (`/home/<user>/...`).

## Adding project-specific setup

Append after the AI installer, sequentially:

```json
"postCreateCommand": "git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh && uv sync"
```

Or split into named steps if some can run in parallel:

```json
"postCreateCommand": {
  "ai-setup": "git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh",
  "project": "uv sync"
}
```

The object form runs entries in parallel — only use it when the project step doesn't depend on the AI install having finished.

## Prerequisites on vossisrv (one-time)

```bash
mkdir -p /home/vossi/devpod/aicodingsetup /home/vossi/devpod/claude /home/vossi/devpod/opencode \
         /home/vossi/devpod/codex /home/vossi/devpod/cursor
chmod 700 /home/vossi/devpod \
          /home/vossi/devpod/aicodingsetup /home/vossi/devpod/claude /home/vossi/devpod/opencode \
          /home/vossi/devpod/codex /home/vossi/devpod/cursor
# Seed initial credentials (from a host where the CLIs are already authed) — all optional.
# Without seeded creds, the first time you run each CLI in a container it prompts for login,
# and the auth file lands in the bind-mounted dir on first write.
scp ~/.claude/.credentials.json                vossi@vossisrv:/home/vossi/devpod/claude/.credentials.json
scp ~/.aicodingsetup/.secrets.env              vossi@vossisrv:/home/vossi/devpod/aicodingsetup/.secrets.env
scp ~/.local/share/opencode/auth.json          vossi@vossisrv:/home/vossi/devpod/opencode/auth.json
scp ~/.codex/auth.json                         vossi@vossisrv:/home/vossi/devpod/codex/auth.json
# Cursor-agent's credential filename isn't publicly documented; rsync the whole ~/.cursor/ dir
# if you want to seed from an already-authed host:
rsync -av ~/.cursor/                           vossi@vossisrv:/home/vossi/devpod/cursor/
ssh vossi@vossisrv 'chmod 600 /home/vossi/devpod/claude/.credentials.json /home/vossi/devpod/aicodingsetup/.secrets.env /home/vossi/devpod/opencode/auth.json /home/vossi/devpod/codex/auth.json'
```

After the first container refreshes any OAuth token, or runs `opencode auth login`, `codex` (sign-in), or `agent login`, vossisrv's copies stay current automatically — write-through via the bind mount.

## MCP behavior to know about

All four CLIs (Claude Code, opencode, codex, cursor-agent) read the same 4 MCP definitions, deployed by `install.sh` to each agent's native config location. Authoring a new MCP means adding it to `configs/mcps.json` in [`vossiman/aiCodingBaseSetup`](https://github.com/vossiman/aiCodingBaseSetup) AND threading it through each CLI's config template (`configs/codex/config.toml`, `configs/cursor/mcp.json`, `configs/opencode/opencode.json`, plus the `install_claude_mcps` block in `install.sh`).

Three categories you'll hit when running `/mcp` in a workspace:

**1. User-scope MCPs** — configured by `install.sh`, live in `~/.claude.json`. Persist across workspaces via the `~/.claude/` bind mount. Anything you `claude mcp add -s user` later also survives.

**2. Project-scope MCPs** — defined in `.mcp.json` at the repo root. *Project scope wins over user scope* when names collide, so a broken project entry will mask a working user-scope MCP of the same name. If a user-scope MCP appears missing, check whether a `.mcp.json` in the repo is silently shadowing it.

Docker-based project MCPs (`docker run …`) only work if the image is present in the dev container's Docker daemon and any bind-mounted paths actually exist on the workspace filesystem. Generated artifacts (e.g. `eval_results.db`) won't be there on a fresh container.

**3. HTTP MCPs with OAuth** (logfire, claude.ai Google Drive, etc.) — show as `needs authentication`. Can't be set up by a script. Auth once via `claude` → `/mcp` → select the MCP → follow the browser link. State lands in `~/.claude/` and rides the bind mount, so every future workspace inherits the auth. Skip ones you don't actively use; unauthed is harmless.

## Why authentication "just works" in this setup

Claude Code reads OAuth tokens from `~/.claude/.credentials.json` *and* checks `~/.claude.json` (file at home root, NOT inside `.claude/`) for `hasCompletedOnboarding: true`. Without that flag, the CLI treats every session as a fresh install and prompts for login regardless of valid tokens. `aiCodingBaseSetup`'s `install.sh` writes that flag automatically; the bind-mounted `.credentials.json` carries the tokens. Together they make container auth seamless.

The same persist-once-share-everywhere property holds for the other three CLIs once their bind mounts are wired: `opencode auth login`, `codex` (first-run ChatGPT sign-in), and `agent login` (cursor-agent) each write their tokens into their respective bind-mounted home directories, so a single login in any container is reusable from every future container. If codex or cursor-agent ever exposes a `hasCompletedOnboarding`-style trap analogous to Claude's, the fix lands in `install.sh` as a parallel `ensure_*_onboarding_state` function — verified empirically at the final-merge gate.

## Future productization (don't do now)

If you end up with 3+ projects using this blueprint, build a custom image that bakes the `install.sh` result into a Docker layer:

```
ghcr.io/vossiman/aiclaude-universal:latest
```

Per-project `.devcontainer/devcontainer.json` shrinks to image + mounts, no `postCreateCommand`. Faster spin-up, less network per `devpod up`. Adds a CI/release pipeline to maintain — only worth it past 3 projects.
