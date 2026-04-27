# DevPod blueprint devcontainer.json

Drop-in `.devcontainer/devcontainer.json` for any project that should come up as a fully-configured AI coding workspace under DevPod (Mint or Win11 client → vossisrv backend).

## How to use

```bash
cd <your-project>
mkdir -p .devcontainer
cp /path/to/devMachine/devpod/blueprint/devcontainer.json .devcontainer/devcontainer.json
git add .devcontainer/devcontainer.json
git commit -m "Add devcontainer config for DevPod"
git push
```

Then from any client:

```bash
devpod up <repo-url>@<branch> --ide cursor
```

First spin-up runs `install.sh` from `aiCodingBaseSetup` — installs Claude Code CLI, opencode, Go, Playwright browsers, MCPs, plugins, skills, hooks, and bw-AICode. Subsequent spin-ups reattach in seconds.

## What each line does

- **`image`** — base devcontainer image. Universal:2 is the kitchen sink (~5 GB), works for any language. Swap for leaner if the project is single-language.
- **`remoteUser`** — must match the image's hardcoded user (see table below).
- **`mounts`** — bind two directories from vossisrv into the container so secrets and Claude credentials persist across workspaces:
  - `aicodingsetup` → `~/.aicodingsetup/` holds `.secrets.env` (API keys for firecrawl, brave, cloudflare).
  - `claude` → `~/.claude/` holds `.credentials.json`, `settings.json`, plugins, hooks, skills. Token refreshes write back to vossisrv, so logging in once persists across every container.
- **`postCreateCommand`** — clones `aiCodingBaseSetup` and runs its installer. The installer detects container mode automatically and auto-installs prerequisites (claude CLI, opencode, Go, Playwright browsers, jq, locales).
- **`postStartCommand`** — runs on *every* container start (including reattach), not just first build. Used here for lightweight tool updates (`claude update`, `opencode upgrade`). Both wrapped in `|| true` so transient network failures never block startup. The object form runs the two updates in parallel.

## Image + remoteUser pairing

The two MUST match the image's default user, or mounts land at the wrong path and nothing works.

| Image | `remoteUser` |
|-------|--------------|
| `mcr.microsoft.com/devcontainers/universal:2` | `codespace` |
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
mkdir -p /home/vossi/devpod/aicodingsetup /home/vossi/devpod/claude
chmod 700 /home/vossi/devpod /home/vossi/devpod/aicodingsetup /home/vossi/devpod/claude
# Seed initial credentials (from a host where claude is already authed)
scp ~/.claude/.credentials.json vossi@vossisrv:/home/vossi/devpod/claude/.credentials.json
scp ~/.aicodingsetup/.secrets.env vossi@vossisrv:/home/vossi/devpod/aicodingsetup/.secrets.env
ssh vossi@vossisrv 'chmod 600 /home/vossi/devpod/claude/.credentials.json /home/vossi/devpod/aicodingsetup/.secrets.env'
```

After the first container refreshes the OAuth tokens, vossisrv's copy stays current automatically.

## MCP behavior to know about

Three categories you'll hit when running `/mcp` in a workspace:

**1. User-scope MCPs** — configured by `install.sh`, live in `~/.claude.json`. Persist across workspaces via the `~/.claude/` bind mount. Anything you `claude mcp add -s user` later also survives.

**2. Project-scope MCPs** — defined in `.mcp.json` at the repo root. *Project scope wins over user scope* when names collide, so a broken project entry will mask a working user-scope MCP of the same name. If a user-scope MCP appears missing, check whether a `.mcp.json` in the repo is silently shadowing it.

Docker-based project MCPs (`docker run …`) only work if the image is present in the dev container's Docker daemon and any bind-mounted paths actually exist on the workspace filesystem. Generated artifacts (e.g. `eval_results.db`) won't be there on a fresh container.

**3. HTTP MCPs with OAuth** (logfire, claude.ai Google Drive, etc.) — show as `needs authentication`. Can't be set up by a script. Auth once via `claude` → `/mcp` → select the MCP → follow the browser link. State lands in `~/.claude/` and rides the bind mount, so every future workspace inherits the auth. Skip ones you don't actively use; unauthed is harmless.

## Why authentication "just works" in this setup

Claude Code reads OAuth tokens from `~/.claude/.credentials.json` *and* checks `~/.claude.json` (file at home root, NOT inside `.claude/`) for `hasCompletedOnboarding: true`. Without that flag, the CLI treats every session as a fresh install and prompts for login regardless of valid tokens. `aiCodingBaseSetup`'s `install.sh` writes that flag automatically; the bind-mounted `.credentials.json` carries the tokens. Together they make container auth seamless.

## Future productization (don't do now)

If you end up with 3+ projects using this blueprint, build a custom image that bakes the `install.sh` result into a Docker layer:

```
ghcr.io/vossiman/aiclaude-universal:latest
```

Per-project `.devcontainer/devcontainer.json` shrinks to image + mounts, no `postCreateCommand`. Faster spin-up, less network per `devpod up`. Adds a CI/release pipeline to maintain — only worth it past 3 projects.
