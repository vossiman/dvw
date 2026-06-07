# dvw client shim — lives in the dvw repo

The bash shim that makes `dvw` talk to this service is **not kept here** — it
lives in its only runnable home, the `vossiman/dvw` repo under `lib/`, where the
`dvw` entrypoint sources it. (dvw sources `$DVW_ROOT/lib/*.sh`; a second copy in
this repo would only drift.)

**Canonical location:** `vossiman/dvw`, branch `feat/catalog-service-client`:

| File (in dvw `lib/`) | Replaces | What changes |
|---|---|---|
| `catalog-http-lib.sh` | (new) | `ssh … curl --unix-socket` transport + HTTP status handling |
| `catalog.sh` | the Dropbox `catalog.sh` | every `catalog_*` call → REST; devpod-local helpers unchanged |
| `ssh-sync.sh` | the Dropbox `ssh-sync.sh` | blueprint via `GET/PUT /v1/blueprint` |
| `connect-resolver.sh` | resolver/probe fns in `connect.sh` | id→container + bulk liveness via the service (no SSH fan-out); sourced after `connect.sh` |

Each keeps the original function's name, signature, stdout, and return-code
contract, so `connect.sh`/`commands.sh`/`wizard.sh` are untouched.

## Config (env, read by the shim)

```bash
export DVW_CATALOG_HOST=vossisrv                         # ssh alias of the box
export DVW_CATALOG_SOCK=/run/dvw-catalog/catalog.sock    # service socket
# export DVW_CATALOG_TOKEN=…                             # only if the service enforces one
```

When `dvw` runs **on** vossisrv (the socket is local) the transport skips SSH
automatically.

## Fallback contract

Every function degrades the way the originals did when the Dropbox mount was
down: read paths print a clear "service unreachable" message and return
non-zero; `_dvw_load_probe` marks all workspaces `unreachable`; the blueprint
refresh is a silent no-op.

> Rollout status and the remaining dvw-side edits (installer, `dvw doctor`, bats)
> are tracked in `docs/superpowers/plans/2026-06-06-catalog-service.md`.
