# Docker proxy and in-container probe: design

Date: 2026-09-01. Tickets: DVW-6 (primary), DVW-4 and DVW-1 (closed by this
work). Repos: dvw (proxy, catalog, TUI, deploy) and aiCodingBaseSetup (probe).

## Problem

The catalog service on vossisrv reaches Docker through a tecnativa
docker-socket-proxy published on `127.0.0.1:2375`. Two facts, both proven by
running the proxy at the pinned digest (DVW-6):

1. tecnativa's ACL is path-prefix plus method. The service needs
   `POST /containers/{id}/exec`, so `POST` on `/containers` is on, and with it
   `POST /containers/create` with an arbitrary bind mount. A compromised
   catalog is still host root.
2. A loopback TCP port has no owner and no mode bits. Every local account and
   every process on vossisrv, including any container on the host network,
   can reach it. The docker group at least gated the socket behind membership.

The proxy narrows the API surface (no images, volumes, networks, build), which
is real, but it neither removes root equivalence nor keeps an access-control
list.

## Goals

- The catalog service has no path to host root, even when fully compromised.
- Only the catalog service user can reach the proxy (unix socket, mode 0600).
- One exec per container gives the catalog everything it reads from inside a
  workspace, so the exec allowlist is a single fixed command.
- The catalog and TUI gain running-agent, git and cgroup facts per workspace.
- The whole path is exercised end to end in the dev container against
  docker-in-docker, including the refused attacks.

Non-goals: image digest lookup through the proxy (the existing "unknown"
degradation stays), container logs and top, any write operation on containers,
a new TUI screen.

## Architecture

```
TUI / dvw CLI ──ssh──> catalog-service (user vossi)
                            │ unix:///run/dvw-docker-proxy/docker.sock  (0600 vossi)
                            ▼
                       dvw-docker-proxy (user dvw-proxy, group docker)
                            │ /var/run/docker.sock
                            ▼
                       dockerd ──exec──> workspace container: dvw-probe → JSON
```

Trust flows one way. The catalog has no Docker access of its own. The proxy is
the only non-root process in the docker group. The probe runs inside a
possibly hostile container and its output is untrusted input to the catalog.

## Component 1: dvw-docker-proxy

Location: `catalog-service/proxy/dvw_docker_proxy.py`, Python 3.12 stdlib
only (`socket`, `selectors`, `http.client`-free hand parsing, `json`, `re`,
`logging`). No dependency on the catalog's venv; it runs with
`/usr/bin/python3`.

### Process model

systemd socket activation:

- `dvw-docker-proxy.socket`: `ListenStream=/run/dvw-docker-proxy/docker.sock`,
  `SocketUser=vossi` (rendered to the installing user like the catalog unit),
  `SocketMode=0600`, `DirectoryMode=0750`. systemd creates the socket at
  boot, so the catalog never observes a gap while the proxy restarts.
- `dvw-docker-proxy.service`: `User=dvw-proxy`, `SupplementaryGroups=docker`,
  `Restart=on-failure`, and the catalog unit's hardening block
  (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=yes`,
  `PrivateTmp`, `RestrictAddressFamilies=AF_UNIX`, `MemoryDenyWriteExecute`).
  It receives the listening socket as fd 3 (`LISTEN_FDS`) and accepts on it.
  Upstream is `/var/run/docker.sock`, overridable with
  `DVW_PROXY_UPSTREAM` for tests; the listener can also be a path via
  `DVW_PROXY_LISTEN` when not socket-activated.

One thread per client connection. Each connection handles exactly one request
(the proxy answers with `Connection: close`), except exec start, which becomes
a bidirectional relay until either side closes.

### Route table

The request line is parsed, an optional `/v1.NN` prefix is stripped, and the
path (without query) is matched against exact patterns. `{id}` is
`[A-Za-z0-9_.-]{1,128}`.

| Method | Path | Condition |
|---|---|---|
| GET | `/_ping` | |
| GET | `/version` | |
| GET | `/info` | |
| GET | `/containers/json` | query passed through |
| GET | `/containers/{id}/json` | |
| GET | `/containers/{id}/stats` | query must contain `stream=false` or `stream=0` |
| POST | `/containers/{id}/exec` | body validated, see below |
| POST | `/exec/{id}/start` | `{id}` was issued by this proxy within 60 s; body `Detach` absent or false |
| GET | `/exec/{id}/json` | `{id}` was issued by this proxy |

Anything else, including `HEAD`, `PUT`, `DELETE`, any `/containers/create`,
`/images`, `/volumes`, `/networks`, `/build`, `/commit`, swarm and system
routes, gets `403 Forbidden` with body
`{"message":"dvw-docker-proxy: route not allowed"}` and the upstream is never
contacted. Malformed requests (no request line, header block over 16 KiB,
body over 64 KiB, chunked request bodies) get `400`.

### Exec create validation

The body is decoded as JSON (`Content-Length` required, max 64 KiB) and must
satisfy all of:

- `Cmd` is a list. Allowed forms:
  - `["dvw-probe"]` (the target state), or
  - one of exactly three argv lists, matched whole and byte for byte: the
    two `tmux list-sessions -F ...` forms and the one `tmux list-windows -t
    work -F ...` form the catalog sends today. Nothing looser is accepted:
    tmux argv is a command language, where a `;` element separates commands
    and a `#(...)` sequence inside a `-F` format string runs a shell job, so
    a prefix match on `["tmux", "list-sessions", ...]` would be a shell.
    Removed together with the catalog fallback in a follow-up PR.
- Absent or false: `Privileged`, `Tty`, `AttachStdin`.
- Absent or empty: `User`, `Env`, `WorkingDir`, `DetachKeys`. Empty is
  checked against the field's own type, so `{"User": {}}` is refused.
- Only the known keys above (`Cmd`, `AttachStdout`, `AttachStderr`,
  `Container`) are re-serialized; every other key is dropped, and
  `AttachStdout`/`AttachStderr` must be booleans.

The validated body is re-serialized by the proxy, not forwarded verbatim, so
key smuggling through duplicate or oddly cased keys is impossible. On success
the proxy records the returned `Id` with a timestamp in an in-memory map
(capacity 256, oldest evicted).

### Exec start relay

`POST /exec/{id}/start` is forwarded after the id check. The upstream reply is
either a plain HTTP response (error) or `101 UPGRADED` followed by the
multiplexed stream. The proxy relays the status line and headers, then copies
bytes in both directions with `selectors` until either peer closes or the
client has received 1 MiB, after which the proxy closes both sides. The client
side write-half is closed as soon as the request body has been sent, since the
exec is never attached to stdin.

### Logging

One journal line per request:
`verdict=allow|deny method=POST path=/containers/abc123/exec cmd=dvw-probe`.
Denied requests include the first 200 bytes of the request line only, never
the body.

## Component 2: dvw-probe

Location: `bin/dvw-probe` in aiCodingBaseSetup. Python 3 stdlib, no
arguments, exit code always 0 once it starts (a missing interpreter yields
127 from Docker, which the catalog uses to detect the absence of the probe).

Installed into `~/.local/bin/dvw-probe` by `lib/provision-integrations.sh`,
the same function shape as `install_agent_notify_symlink`, so every running
container receives it at boot sync without an image rebuild. Exec runs as the
container's default user with the login `PATH`, so the exec `Cmd` needs no
path.

### Output

One JSON object on stdout, schema version 1:

```json
{
  "schema": 1,
  "ts": 1756800000,
  "partial": false,
  "tmux": {
    "sessions": [{"name": "work", "attached": 1, "activity": 1756799990}],
    "windows": [{"id": "@7", "name": "claude", "active": true,
                 "activity": 1756799990, "waiting_since": null,
                 "command": "node"}]
  },
  "agents": [{"cli": "claude", "pid": 4242, "started": 1756790000,
              "cwd": "/workspaces/foo"}],
  "git": {"root": "/workspaces/foo", "branch": "feat/x", "head": "abc1234",
          "dirty": true, "ahead": 2, "behind": 0},
  "cgroup": {"mem_current": 1234, "mem_max": 8589934592,
             "cpu_usec": 123456, "nr_procs": 42}
}
```

Any section that cannot be computed is `null`. A section whose collector
exceeds its budget is `null` and `partial` becomes `true`.

### Collectors

- `tmux`: `tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_activity}'`
  and `tmux list-windows -t work -F '#{window_id}\t#{window_name}\t#{window_active}\t#{window_activity}\t#{@waiting}\t#{pane_current_command}'`,
  the same fields the catalog reads today. Windows are read for the `work`
  session only; if it does not exist, `windows` is `[]`.
- `agents`: scan `/proc/[0-9]*/comm` and `cmdline`; a process counts when its
  comm or argv[0] basename, or argv[1] basename for `node`/`python` wrappers,
  is one of `claude`, `codex`, `cursor-agent`, `opencode`. `started` comes
  from `/proc/<pid>/stat` starttime plus boot time, `cwd` from
  `readlink /proc/<pid>/cwd`. Processes owned by other users are skipped
  silently.
- `git`: root is the first existing of `$WORKSPACE_FOLDER`,
  `/workspaces/<only dir>`, else `null`. `git rev-parse --abbrev-ref HEAD`,
  `git rev-parse --short HEAD`, `git status --porcelain` (dirty if non-empty),
  `git rev-list --left-right --count HEAD...@{upstream}` (ahead/behind, null
  when no upstream). Each call has a 2 s timeout.
- `cgroup`: `/sys/fs/cgroup/memory.current`, `memory.max` (`max` becomes
  `null`), `cpu.stat` `usage_usec`, `pids.current`.

Environment overrides for tests: `DVW_PROBE_PROC`, `DVW_PROBE_CGROUP`,
`DVW_PROBE_WORKSPACE`, and a fake `tmux` and `git` on `PATH`.

Wall-clock budget 3 s total; collectors run sequentially with per-collector
deadlines, so a hung tmux server cannot starve the rest.

## Component 3: catalog service changes

`app/probe.py` (new):

- `ProbeReport` pydantic model mirroring the schema above, `extra="ignore"`,
  every field optional, list lengths capped (`sessions` 64, `windows` 256,
  `agents` 64), strings capped at 512 chars. Parsing failures raise
  `ProbeError`.
- `run_probe(container) -> ProbeReport | None`: `exec_run(["dvw-probe"],
  demux=True)`. Output over 256 KiB is discarded. Exit codes 126 and 127 raise
  `ProbeMissing`; any other non-zero or parse failure returns `None` after a
  warning log with the container id.

`app/docker_inspect.py`:

- The three tmux `exec_run` sites become one `_probe_or_tmux(c)` that calls
  `run_probe` once per container per request and derives activity, attached
  count and windows from it. On `ProbeMissing` it falls back to the existing
  tmux calls and records `probe: "missing"`. The fallback is removed in a
  follow-up once every running workspace has synced.
- Results are memoized per `container_id` for the duration of one request
  (a dict created in the router and passed down), so `/containers/status` and
  `/containers/windows` never exec twice for the same container.
- `ContainerInspect` gains `agents: list[AgentProc]`, `git: GitState | None`,
  `probe: str` (`ok`, `partial`, `missing`, `failed`). `_cpu_mem` keeps using
  `stats`, because the cgroup numbers inside the container lack the host
  system-cpu delta needed for a percentage; `cgroup.mem_current` is used only
  when `stats` fails.

`app/config.py`: `docker_host` default becomes
`unix:///run/dvw-docker-proxy/docker.sock`; `catalog.env.example` documents
it. `docker.from_env()` is no longer a code path.

`RestrictAddressFamilies` in `dvw-catalog.service` drops `AF_INET AF_INET6`.

## Component 4: TUI

`tui/dvw_tui/render.py` inspect view gains two lines under the existing
memory meter: `agents: claude (2h 10m, /workspaces/foo), codex (5m)` and
`git: feat/x +2 -0 dirty`. Missing data renders as `agents: none` and
`git: unknown`. The workspace tree label is unchanged. `client.py` passes the
new fields through; `render.py` tests cover both populated and null cases.

## Component 5: deploy

`host-install.sh`:

- Creates `dvw-proxy` if absent: `useradd --system --no-create-home
  --shell /usr/sbin/nologin -G docker dvw-proxy`.
- Installs `deploy/dvw-docker-proxy.socket` and `.service` (rendered
  `SocketUser=` to the installing user), `daemon-reload`, `enable --now` the
  socket, readiness check `curl --unix-socket /run/dvw-docker-proxy/docker.sock
  http://localhost/_ping` (30 × 1 s).
- Writes `CATALOG_DOCKER_HOST=unix:///run/dvw-docker-proxy/docker.sock` into
  `catalog.env` when the key is absent or still points at `tcp://`.
- If the tecnativa compose project exists, `docker compose -f
  deploy/docker-proxy.compose.yml down` is attempted before the file is
  removed from the checkout; the installer tolerates its absence.
- Sudoers drop-in gains `systemctl restart dvw-docker-proxy.socket
  dvw-docker-proxy.service` for `host-update.sh`.

`host-update.sh` treats the two proxy units like the catalog units: rendered
compare, reinstall on change, `daemon-reload`, restart the socket unit, then
the existing catalog restart and smoke test. The smoke test also pings the
proxy socket.

`deploy/docker-proxy.compose.yml` is deleted. `deploy/docker-socket-proxy.md`
is rewritten as `deploy/docker-proxy.md`: what the proxy allows, why exec is
limited to the probe, how to add a route, and the migration note for hosts
that ran tecnativa.

## Component 6: testing

### Unit

- Proxy (`catalog-service/tests/test_proxy.py`): a fake upstream on a
  temporary unix socket implemented with `socketserver`, scripted per test.
  Cases: each allowed route passes with query intact; version prefix
  stripped; every denied route returns 403 without upstream contact;
  exec-create bodies (probe ok, tmux transitional ok, `sh` denied,
  `Privileged` denied, `User` denied, oversize denied, duplicate keys
  normalized); exec start with unknown id denied; exec start relays an
  upgraded stream both ways and stops at 1 MiB; `stats` without
  `stream=false` denied; malformed request line 400.
- Probe (`tests/bats/dvw-probe.bats` in aicoding): fake `tmux` and `git`
  scripts on `PATH`, fixture `/proc` and cgroup trees via the env overrides;
  asserts schema, `partial` on a sleeping fake tmux, `null` sections when
  tools are missing, exit 0 in every case, output is valid JSON with
  `python3 -m json.tool`.
- Catalog (`tests/test_probe.py`, `test_api_*`): `FakeInspector` grows a
  scripted probe; oversize output ignored; wrong types rejected; 127 triggers
  fallback; `/containers/status` and `/containers/windows` exec once per
  container; inspect payload carries agents and git.

### End to end (docker-in-docker)

`tests/e2e/dind.sh` in dvw, run in the dev container:

1. Start `docker:dind` privileged on a private network with
   `DOCKER_TLS_CERTDIR=` and a named volume, wait for `/_ping`.
2. Build a `dvw-e2e-workspace` image (debian-slim, `tmux`, `git`,
   `python3`) with `dvw-probe` copied from a path given by
   `DVW_PROBE_SRC` (default: the aicoding checkout next to this repo). Start
   two containers labeled `dev.containers.id=<ws>` with a `work` tmux session,
   one window running a fake `claude` process, and a git repo on a branch.
3. Run the proxy from the worktree as the current user with
   `DVW_PROXY_UPSTREAM=tcp://<dind>:2375` and `DVW_PROXY_LISTEN=$TMP/proxy.sock`.
   The upstream is TCP only inside this harness; production is a unix path.
4. Run the catalog from the worktree venv with
   `CATALOG_DOCKER_HOST=unix://$TMP/proxy.sock` on `$TMP/catalog.sock`.
5. Assert with curl: `/containers/status` lists both workspaces as running;
   `/containers/windows` shows the window with a command and activity;
   `/workspaces/<id>/inspect` shows `agents[0].cli == "claude"` and
   `git.branch`; then the attacks straight at the proxy socket:
   `POST /containers/create` with `Binds ["/:/host"]` → 403,
   `POST /containers/<id>/exec` with `Cmd ["sh"]` → 403, `GET /images/json`
   → 403, exec start with a fabricated id → 403. Finally the proxy journal
   (stderr) contains a `deny` line for each.
6. `--keep` leaves everything running and prints the env needed for a TUI
   playtest: `DVW_CATALOG_SOCK=$TMP/catalog.sock python -m dvw_tui`. The
   playtest checks the tree, the inspect view with agents and git, and the
   waiting marker after `agent-notify` is run inside a workspace container.
7. Teardown removes containers, network and volume.

The script is also runnable as `tests/bats/e2e-dind.bats` behind
`DVW_E2E=1`, so the normal suite stays fast.

## Rollout

1. aicoding PR: probe plus bats tests. Merge, containers pick it up at next
   boot sync.
2. dvw PR: proxy, catalog, TUI, deploy, e2e. Merge, then on vossisrv run
   `sudo /opt/dvw/catalog-service/deploy/host-install.sh` once (creates the
   user, installs the units, rewrites env, removes tecnativa), followed by the
   smoke test. Verify `ss -xl | grep dvw-docker-proxy`, `id dvw-proxy`, and
   that `vossi` is not in the docker group.
3. Follow-up PR after all workspaces have synced: remove the tmux
   transitional allowlist entry and the catalog fallback.
4. Tickets: DVW-6 done; DVW-4 done (systemd owns liveness); DVW-1 done
   (superseded). devMachine submodule bumps as usual.

## Risks

- The exec relay is the one piece of non-trivial socket code. It is covered
  by a unit test with a scripted upgraded stream and by the DIND run, which
  exercises the real dockerd framing.
- A probe that is slow inside a loaded container delays `/containers/status`.
  The 3 s budget bounds it; the catalog's existing per-request timeout stays.
- Hosts that installed before this change keep working until
  `host-install.sh` is re-run; `host-update.sh` alone does not create the
  user, and says so if the proxy socket is missing.
