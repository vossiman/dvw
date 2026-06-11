# dvw-catalog

Authoritative DevPod workspace **catalog + container resolver**, running on
`vossisrv`. Replaces three Dropbox-coupled pieces of the `dvw` workflow with one
small FastAPI service that has **local Docker access**:

1. the Dropbox-synced `catalog.json` (which workspaces exist),
2. the Dropbox-synced `ssh-blueprint.conf`, and
3. dvw's client-side, SSH-bound *canonical-container resolver* (id → container).

Because the service lives **on the box with the Docker socket**, it answers
"which container is workspace X, right now?" authoritatively and in
milliseconds — no rclone FUSE mount, no 30 s poll, no `*conflicted copy*` files,
no cross-machine write-races, no slug heuristics over SSH.

> Design rationale and the full dvw-integration plan live in the devMachine
> repo under `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Architecture in one picture

```
laptop (Mint / WSL)                         vossisrv (Ubuntu 24.04)
┌────────────────┐   ssh + curl            ┌──────────────────────────────┐
│ dvw (bash)     │ ──unix-socket curl────▶ │ dvw-catalog (FastAPI/uvicorn) │
│  dvw lib/*.sh  │                         │  /run/dvw-catalog/catalog.sock │
└────────────────┘                         │   ├─ catalog.json (atomic)     │
   no Dropbox.                             │   ├─ ssh-blueprint.conf        │
   no open TCP port.                       │   └─ docker.sock ──▶ deep inspect
                                           └──────────────────────────────┘
```

No TCP port is ever opened: uvicorn binds a unix socket, and clients reach it
over the SSH they already use (`ssh vossisrv -- curl --unix-socket …`). SSH key
auth + `0660 vossi:vossi` socket perms *is* the auth boundary.

## API (`/v1`)

| Method & path | Purpose |
|---|---|
| `GET /health` | liveness: docker reachable? store writable? workspace count |
| `GET /catalog` | whole catalog, legacy schema (for `dvw doctor` / jq) |
| `GET /workspaces` | list, MRU order |
| `GET /workspaces/{id}` · `POST` · `PATCH` · `DELETE` | workspace CRUD |
| `POST /workspaces/{id}/touch` | bump `last_used_at` |
| **`GET /workspaces/{id}/container`** | **resolve canonical container** (bind-mount + tmux tie-break) |
| **`GET /workspaces/{id}/inspect`** | **deep inspect**: state, health, mounts, cpu/mem, disk, liveness |
| `GET /repos` · `GET /repos/by-url` · `POST` | repo MRU + per-repo last branch |
| `GET /defaults` · `PUT /defaults` | global ide/provider defaults |
| `GET /blueprint` · `PUT /blueprint` | ssh-blueprint (replaces the Dropbox file) |
| `GET /containers/status` | bulk liveness (alive/stale/stopped/absent) — replaces dvw's SSH probe |
| `GET /containers/orphans` | devpod-labelled containers not in the catalog |

Interactive docs at `/docs` (over the socket: `ssh vossisrv -- curl --unix-socket … http://localhost/openapi.json`).

## Layout

```
app/                FastAPI service
  main.py           app factory, lifespan, error envelope, router wiring
  config.py         env-driven settings (CATALOG_*)
  models.py         pydantic v2 — legacy catalog.json schema + resolver results
  store.py          atomic single-writer JSON store (tmp+fsync+rename, asyncio.Lock)
  docker_inspect.py local docker: resolver, deep inspect, bulk status, orphans
  deps.py           DI providers, auth, threadpool bridge, resolve TTL cache
  routers/          health, catalog, workspaces, repos, defaults, blueprint, containers
clients/            pointer to the dvw bash shim (the shim itself lives in dvw/lib/)
deploy/             systemd units, backup timer, deploy.sh, socket-proxy hardening
tests/              pytest suite (CRUD, resolver tie-break parity, store)
```

## Develop

```bash
uv venv && uv pip install -e ".[dev]"
.venv/bin/python -m pytest -q          # 36 tests, no docker daemon required
uv run uvicorn app.main:app --reload   # dev server on http://127.0.0.1:8000
```

The test suite fakes the Docker layer via dependency overrides, so it runs
anywhere. The resolver tie-break tests drive the *real* `DockerInspector`
against a fake docker client to pin dvw's exact semantics.

## Deploy

Runs as a **systemd service on vossisrv**, deployed from a git checkout on the
box (so updates are `git pull`, no laptop in the loop).

**First time** — run as `vossi` on vossisrv:

```bash
sudo install -d -o "$USER" -g "$USER" /opt/dvw
git clone -b main https://github.com/vossiman/dvw.git /opt/dvw
/opt/dvw/catalog-service/deploy/host-install.sh
# (until PR #9 merges: clone -b feat/catalog-service-client, or BRANCH=feat/catalog-service-client host-install.sh)
```

`host-install.sh` is idempotent: it symlinks `/opt/dvw-catalog` → the checkout
(so the systemd unit is path-stable across pulls), creates the `/var/lib/dvw-catalog`
data dir + its git-backup repo, `uv sync --frozen`s the venv, installs the units,
adds a narrow passwordless-restart sudoers drop-in, enables + starts everything,
and smoke-tests `/v1/health`.

**Updates** — one command on the box:

```bash
/opt/dvw/catalog-service/deploy/host-update.sh   # git pull + uv sync + restart
```

**Seeding the catalog** — the service starts with an empty catalog. To import an
existing `catalog.json` (and `ssh-blueprint.conf`), copy them into the data dir,
then `restart` — `catalog.json` is loaded and validated on startup. Use
`restart` (not `stop`/`start`): it's the verb the install's sudoers drop-in
whitelists passwordless, and on this single-writer box nothing mutates the
catalog during the copy, so the on-disk file you just dropped in wins.

```bash
# from wherever the files live, e.g. your dev box:
scp catalog.json       vossi@vossisrv:/var/lib/dvw-catalog/catalog.json
scp ssh-blueprint.conf vossi@vossisrv:/var/lib/dvw-catalog/ssh-blueprint.conf
# then on vossisrv (the .service suffix matches the passwordless sudoers rule):
sudo systemctl restart dvw-catalog.service
```

Alternative (no git on the box): `REMOTE=vossi@vossisrv ./deploy/deploy.sh`
rsyncs from a laptop instead.

Hardening (recommended): front the Docker socket with a read-mostly proxy and
drop the `docker` group — see `deploy/docker-socket-proxy.md`.

## Configuration

All env vars are prefixed `CATALOG_` (see `deploy/catalog.env.example`):
`CATALOG_DATA_DIR`, `CATALOG_DOCKER_HOST`, `CATALOG_TOKEN`,
`CATALOG_RESOLVE_CACHE_TTL`. Clients use `DVW_CATALOG_HOST` / `DVW_CATALOG_SOCK`
/ `DVW_CATALOG_TOKEN`.
