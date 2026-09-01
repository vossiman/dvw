# dvw

Host-side DevPod workspace orchestrator (catalog + connect + wizard + TUI).
Integrating via PR is the convention here, and merged branches get deleted,
but this is not enforced: `main` carries no branch protection or rulesets
(verified with `gh` at admin visibility, 2026-08-31). Ask before merging.

## Architecture (as of 2026-07)

- **Catalog service** on the provider owns workspace metadata, SSH blueprint,
  and Docker inspection (`catalog-service/`).
- **Client** reaches the service over SSH + unix-socket curl
  (`lib/catalog-http-lib.sh`). Probe/resolve live in `lib/connect-resolver.sh`
  (sourced after `lib/connect.sh`); do not reintroduce SSH docker fan-out in
  `connect.sh`.
- **Two catalog transports:** bash CLI uses per-call SSH + `curl --unix-socket`
  (`catalog-http-lib.sh`); the TUI may use `ssh -L` forwarded socket. If TUI
  can't see the catalog but `dvw status` works, compare those paths (`dvw doctor`
  prints the effective endpoint).
- **aicoding** owns in-container life (`devcontainer.json`, install/sync).
  dvw only seeds that file (`DVW_BLUEPRINT_DEVCONTAINER_URL`, tip-of-main by
  default) and orchestrates DevPod.
- **Image pin reconciliation** (`lib/pin.sh` / `lib/pin-rebuild.sh`) is the one exception: aicoding's
  boot sync rewrites a workspace's `.devcontainer/devcontainer.json` pin but
  deliberately never commits it, while `devpod up --recreate` builds from the
  committed copy. `dvw pin-rebuild <id>` is the one-stop closing loop (live-branch PR, verified merge gate, source-clone pull via catalog service, rebuild, image assertion). `dvw pin-sync` is retained for fleet-wide sweeps across many repos. The catalog service requires redeployment (`catalog-service/deploy/host-update.sh`) before the new endpoints work; old client plus new server (and vice versa) degrade gracefully to today's behavior. Consumer discovery is free here — the catalog already lists every workspace's `repo@branch`.

### Naming: “blueprint” means two things

1. **SSH blueprint** — catalog `GET/PUT /v1/blueprint` → local `~/.ssh/dvw.conf`
2. **aicoding blueprint** — the aiCodingBaseSetup clone / `devcontainer.json`
   seed (`DVW_BLUEPRINT_DEVCONTAINER_URL`)

## Updates

- Standalone checkout: `dvw update` (pull main + reinstall).
- Submodule under a parent (e.g. `devMachine`): `dvw update` **follows the
  parent's pins** — ff the parent to its `origin/main`, check submodules out at
  the pinned commits, reinstall. It never commits or pushes; moving the pins
  forward is the parent's job (`scripts/update-submodules.sh` in devMachine).
  It refuses when the parent is off `main`, dirty (including dirty submodule
  contents), or can't fast-forward. See `lib/update-super.sh`.
- The "behind main" nudge measures the **parent** in submodule mode, so the
  count is exactly what `dvw update` resolves (`lib/update-check.sh`).

## Tests

```bash
./tests/bats/run.sh
```

Also: `catalog-service/` and `tui/` pytest suites.
