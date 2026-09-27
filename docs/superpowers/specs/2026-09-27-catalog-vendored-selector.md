# Catalog: vendor the aicoding CI selector (DVW-27)

## Problem

The catalog resolves the blueprint image by asking `aicoding-select aicoding`
for the latest CI-qualified aiCodingBaseSetup main commit
(`catalog-service/app/blueprint_image.py`, `_select_sha`). That command comes
from an aicoding install in the service user's `~/.local/bin`. vossisrv has
never had one, so every refresh fails with exit 127 and the image-staleness
comparison is always unknown. Since dvw #87, `host-update.sh` runs the same
prerequisite check as `host-install.sh`, so the deploy now refuses outright.

## Decision

Owner decision, 2026-09-27: vossisrv gets no aicoding install. dvw carries a
byte-identical copy of the selector instead.

- The rule "latest CI-green aicoding main" stays the single source. The copy
  vendors code, not a pinned SHA, so nothing needs bumping when aicoding
  releases.
- No dependency on devMachine submodule pins; devMachine #52 removes them.
- The explicit `CATALOG_BLUEPRINT_DEVCONTAINER_URL` override keeps working
  unchanged and still wins when set.

## Layout

```
catalog-service/vendor/aicoding/
  bin/aicoding-select        verbatim from aiCodingBaseSetup main
  lib/ci-selector.sh         verbatim
  lib/update-progress.sh     verbatim (sourced by ci-selector.sh)
  SOURCE                     upstream repo, commit, path and sha256 per file
  refresh.sh                 fetch upstream main; --check compares only
```

`aicoding-select` resolves its library directory from its own real path
(`dirname "$(dirname "$(readlink -f "$0")")"`), so the copy runs in place with
no edits. `SOURCE` is provenance for humans and the drift check; nothing at
runtime reads it, and it never selects a version.

## Resolution

- `blueprint_image.py` runs the vendored script by absolute path
  (`<catalog-service>/vendor/aicoding/bin/aicoding-select aicoding`), wrapped in
  the existing `timeout`. It no longer looks up `aicoding-select` on `PATH`, so
  a stale aicoding install on some host cannot shadow the vendored copy.
- `blueprint-preflight.sh` keeps the URL branch unchanged. Without a URL it
  checks that the vendored script is executable and that `jq`, `timeout`, and
  `gh` or `curl` exist. The error text names the vendored path and the missing
  tools, and no longer suggests installing aicoding.
- `host-install.sh` and `host-update.sh` need no flow change: both already
  source the preflight, and `host-install.sh` already re-execs when the pull
  changes the preflight helper.

## Runtime dependencies and API budget on vossisrv

- Tools: `bash`, `jq`, coreutils `timeout`, and `curl` (or `gh`). The
  selector tries `gh api` first and falls back to unauthenticated `curl`
  against `api.github.com`. The service gets no token: nothing new reads the
  secrets store or puts a credential in the environment.
- One selection costs about 3 requests after aiCodingBaseSetup #201 (workflow
  metadata, main history, one bulk runs page), plus a per-commit query only
  when the bulk page cannot prove coverage.
- Unauthenticated GitHub allows 60 requests per hour per IP, shared with
  anything else on vossisrv that calls the API anonymously.
- Today a failed refresh retries after at most 60 s (`_FAILURE_TTL_CAP`). With
  a selector failure that would be up to about 180 requests per hour, which
  keeps a rate-limited host rate-limited. Change: cache the selected SHA
  separately from the image fetch, reuse it for `blueprint_image_ttl`
  (900 s), and back off 900 s after a selector failure. The image fetch from
  raw.githubusercontent.com keeps its 60 s failure cap, since it is not
  subject to the API limit. Steady state is then about 12 API requests per
  hour.

## Drift detection

- `refresh.sh` downloads the three files from
  `https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/`
  (public repo, no auth), and rewrites them and `SOURCE`. `refresh.sh --check`
  only compares and exits non-zero on a difference, naming the files.
- A separate workflow, `.github/workflows/vendor-drift.yml`, runs
  `refresh.sh --check` daily, on `workflow_dispatch`, and on pull requests that
  touch `catalog-service/vendor/**`.
- It must NOT be part of `ci.yml`. The aicoding updater qualifies dvw releases
  on `ci.yml` (`_aicoding_ci_policy dvw`), so an upstream selector change
  turning `ci.yml` red would freeze dvw updates on every machine.
- A red drift run means: run `refresh.sh`, review the upstream diff, open a
  PR.

## Test plan

- pytest: `_select_sha` invokes the vendored absolute path (not `PATH`); exit
  codes 0/1/2/124/127 map as today; the selected SHA is reused within the TTL;
  a selector failure backs off 900 s while an image-fetch failure keeps the
  60 s cap.
- bats: preflight passes with the vendored script plus `jq`, `timeout` and
  `curl` stubs and no `aicoding-select` on `PATH`; it fails naming a missing
  `jq`; the URL override path is unchanged.
- bats: `refresh.sh --check` passes when the files match a stubbed upstream,
  fails naming the file on a one-byte difference; `refresh.sh` rewrites files
  and `SOURCE`. Network is stubbed (a `curl` shim), so CI stays offline.
- An integrity test asserts each vendored file's sha256 matches `SOURCE`, so a
  hand edit to the copy fails `ci.yml` without any network.

## Rollout

On vossisrv, as `vossi`: `/opt/dvw/catalog-service/deploy/host-update.sh`.
If the preflight then names a missing tool (most likely `jq`), install it
with apt and rerun. No aicoding install, no catalog.env change.
