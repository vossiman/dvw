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
- **aicoding** owns in-container life (`devcontainer.json`, install/sync).
  dvw only seeds that file (`DVW_BLUEPRINT_DEVCONTAINER_URL`, tip-of-main by
  default) and orchestrates DevPod.

## Updates

- Standalone checkout: `dvw update` (pull main + reinstall).
- Submodule under a parent (e.g. `devMachine`): **refuse** `dvw update`; bump
  the parent submodule pointer instead.

## Tests

```bash
./tests/bats/run.sh
```

Also: `catalog-service/` and `tui/` pytest suites.
