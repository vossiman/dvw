# dvw

Host-side DevPod workspace orchestrator (catalog + connect + wizard + TUI).
`main` is protected — integrate via PR; ask before merging; delete merged
branches.

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

### Naming: “blueprint” means two things

1. **SSH blueprint** — catalog `GET/PUT /v1/blueprint` → local `~/.ssh/dvw.conf`
2. **aicoding blueprint** — the aiCodingBaseSetup clone / `devcontainer.json`
   seed (`DVW_BLUEPRINT_DEVCONTAINER_URL`)

## Updates

- Standalone checkout: `dvw update` (pull main + reinstall).
- Submodule under a parent (e.g. `devMachine`): **refuse** `dvw update`; bump
  the parent submodule pointer instead.

## Tests

```bash
./tests/bats/run.sh
```

Also: `catalog-service/` and `tui/` pytest suites.
