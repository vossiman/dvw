# dvw-catalog

Authoritative DevPod workspace **catalog + container resolver**, running on the
Docker host (`vossisrv` in the reference deployment — the install adapts to
whatever user/host you run it on). One small FastAPI service with **local Docker
access** that owns three things:

1. the `catalog.json` (which workspaces exist),
2. generated SSH defaults plus persistent custom overrides, and
3. the *canonical-container resolver* (workspace id → container).

Because the service lives **on the box with the Docker socket**, it answers
"which container is workspace X, right now?" authoritatively and in
milliseconds — no client-side polling, no cross-machine write-races, no slug
heuristics over SSH.

> Design rationale and the full dvw-integration plan live in the devMachine
> repo under `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Architecture in one picture

```
laptop (Mint / WSL)                         vossisrv (Ubuntu 24.04)
┌────────────────┐   ssh + curl            ┌──────────────────────────────┐
│ dvw (bash)     │ ──unix-socket curl────▶ │ dvw-catalog (FastAPI/uvicorn) │
│  dvw lib/*.sh  │                         │  /run/dvw-catalog/catalog.sock │
└────────────────┘                         │   ├─ catalog.json (atomic)     │
   no sync layer.                          │   ├─ ssh-blueprint*.conf       │
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
| `GET /blueprint` · `PUT /blueprint` | effective SSH blueprint; PUT remains compatible with whole-file clients |
| `GET /blueprint/custom` · `PUT /blueprint/custom` | persistent operator overrides with optimistic revision checks |
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
  blueprint_store.py generated defaults, legacy migration, overrides, atomic materialization
  docker_inspect.py local docker: resolver, deep inspect, bulk status, orphans
  deps.py           DI providers, auth, threadpool bridge, resolve TTL cache
  routers/          health, catalog, workspaces, repos, defaults, blueprint, containers
clients/            pointer to the dvw bash shim (the shim itself lives in dvw/lib/)
deploy/             systemd units, backup timer, host-install.sh/host-update.sh, socket-proxy hardening
tests/              pytest suite (CRUD, resolver tie-break parity, store)
```

## Develop

```bash
uv venv && uv pip install -e ".[dev]"
.venv/bin/python -m pytest -q          # no docker daemon required
uv run uvicorn app.main:app --reload   # dev server on http://127.0.0.1:8000
```

The test suite fakes the Docker layer via dependency overrides, so it runs
anywhere. The resolver tie-break tests drive the *real* `DockerInspector`
against a fake docker client to pin dvw's exact semantics.

## Deploy

Runs as a **systemd service on the Docker host** (the reference host is
`vossisrv`), deployed from a git checkout on the box (so updates are `git pull`,
no laptop in the loop). `host-install.sh` rewrites the units' `User=`/`Group=`
to whoever runs it, so it isn't tied to `vossi`.

**First time** — run as your normal user on the host (reference: `vossi@vossisrv`):

```bash
sudo install -d -o "$USER" -g "$USER" /opt/dvw
git clone -b main https://github.com/vossiman/dvw.git /opt/dvw
/opt/dvw/catalog-service/deploy/host-install.sh
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
existing `catalog.json` and legacy `ssh-blueprint.conf`, copy them into the data
dir, then `restart`. The blueprint migrates on first API access. Use
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

## SSH blueprint persistence

The effective `ssh-blueprint.conf` is a generated compatibility artifact. Its
sources are:

- managed defaults embedded in the service and versioned with the code;
- `ssh-blueprint.custom.conf`, which contains durable operator overrides; and
- `ssh-blueprint.meta.json`, which records schema and managed-default versions.

On first access, an existing raw blueprint is backed up to
`ssh-blueprint.legacy.bak`. Recognized historical defaults are removed while
unknown content is preserved byte-for-byte as custom configuration. Generated
blocks are always recognized as generated, whatever their version and however
the copy's final newline survived the trip — the documented `scp` seeding path
loses it, and a file dropped in that way must migrate rather than be mistaken
for operator data. The effective file is then written atomically with custom
directives first, because OpenSSH uses the first value it obtains for each
parameter.

Note that `GET` writes: it migrates, repairs and rematerializes on demand, so
the data dir has to be writable. Reads never fail on recoverable state — if
generated markers ever end up inside the custom file, the next read strips them
and reports `custom_sanitized`, because a rejected read has no recovery path
through the API and would wedge every later request.

Use `PUT /v1/blueprint/custom` with the revision returned by
`GET /v1/blueprint/custom` (or `If-Match`) for explicit updates. The legacy
whole-file `PUT /v1/blueprint` remains available: it accepts raw custom content
or an effective document generated by this service (any managed version;
trailing newlines are normalized, so a round trip through a shell's `$(...)` is
not mistaken for an edit). Requests with a stale revision, a genuinely edited
managed section, or metadata from a newer service schema return `409` rather
than silently losing or downgrading configuration. Every request serializes on
one lock, and the blocking file I/O runs off the event loop.

Hardening (recommended): front the Docker socket with a read-mostly proxy and
drop the `docker` group — see `deploy/docker-socket-proxy.md`.

## Configuration

All env vars are prefixed `CATALOG_` (see `deploy/catalog.env.example`):
`CATALOG_DATA_DIR`, `CATALOG_DOCKER_HOST`, `CATALOG_TOKEN`,
`CATALOG_RESOLVE_CACHE_TTL`. Clients use `DVW_CATALOG_HOST` / `DVW_CATALOG_SOCK`
/ `DVW_CATALOG_TOKEN`.
