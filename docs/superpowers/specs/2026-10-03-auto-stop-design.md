# Automatic workspace stop after idle: design

Date: 2026-10-03. Ticket: DVW-18. Status: draft for review.

## Goal

The catalog already measures how long each workspace has been idle
(`catalog-service/app/activity.py`), but only reports it. This design makes
the catalog stop a workspace container once it has been continuously idle
for its timeout, and tidies how the TUI shows idle state.

Success means:

- An idle workspace is stopped after its timeout (default 60 minutes) and
  starts again on the next `dvw <id>`.
- A workspace with a live session, a running agent, a T3 server or an
  `always_on` flag is never stopped.
- Any doubt about a measurement blocks the stop.
- Nothing is ever deleted. The only new capability is "stop one DevPod
  workspace container".

## Decisions already made (owner, 2026-10-03)

1. Enforcement is fleet-wide, not opt-in per workspace.
2. A workspace that runs a T3 server is exempt as a general rule.
3. The stop is a Docker-level stop sent by the catalog through its existing
   Docker proxy, with one new allowlisted route. Chosen as the slimmest
   option. A separate host-side stopper running `devpod stop` is the
   fallback if gate 0 below fails.
4. No special handling for containers with an old probe. Every container on
   the fleet runs the current probe (checked 2026-10-03: all 11 workspaces
   report a full signals block).

## Non-goals

- No new CLI or TUI control for `always_on` or `idle_timeout_minutes`. They
  stay settable through the existing `PATCH /v1/workspaces/{id}` fields.
- No stop of duplicate, orphaned or non-catalog containers.
- No start, restart, kill or remove capability in the proxy.
- No resource-based rules (CPU, memory). Idle is defined only by the probe
  signals.

## Gate 0: check the stop mechanism before writing code

Decision 3 rests on an assumption that has not been tested on this fleet:
that a Docker-level stop leaves DevPod in a state it restarts cleanly from.
`lib/connect.sh:66-93` suggests it does (a stopped container falls through
to the `<id>.devpod` alias, whose ProxyCommand runs DevPod's implicit up),
but that path has not been exercised after a plain `docker stop`.

On vossisrv, with an idle workspace nobody needs (`dataenv-git-devpod`):

1. `docker stop -t 30 <container>`.
2. Confirm the catalog reports `liveness: stopped` and the activity state
   `stopped`.
3. Confirm the container stays stopped for ten minutes (no restart policy
   or DevPod daemon brings it back).
4. `dvw dataenv-git-devpod` from a client. It must start the same
   container (same container id, no twin, no recreate) and open the
   session with the workspace content intact.

If any step fails, stop and revise this spec to the fallback (host-side
stopper running `devpod stop`). Sections "T3 exemption", "Decision rule"
and "TUI" are unaffected by that switch.

## Design

### 1. T3 exemption (probe signal, aiCodingBaseSetup)

`bin/dvw-probe` gains one field in its activity block: `t3_servers`, the
number of running T3 server processes in the container. A T3 server is a
process whose executable basename is `t3` and whose first argument is
`serve` (today: `.../t3-linux-x64/t3 serve <dir>`). It follows the same
rule as the other counters: an integer when the `/proc` scan was complete,
`null` when it was not.

In the catalog, `ProbeActivity` (`app/probe.py`) gains
`t3_servers: int | None`. It is not an activity signal. It is an exemption:

- `t3_servers > 0`: state `always-on`, with the reason `t3`.
- `t3_servers == 0`: no effect.
- `t3_servers` null or absent: the sample is not complete, so the state is
  `unknown`, exactly like a null in any existing signal. This needs no code
  beyond adding the field to the "all integers" check.

The stored `always_on` flag is unchanged and remains the manual exemption
for other service-hosting workspaces. It takes precedence in the display
(`always-on`, no reason).

The exemption is on "server running", not "T3 installed", so removing or
stopping T3 lifts it without anyone editing the catalog.

### 2. Decision rule (catalog)

The observer keeps doing what it does today. Its docstring promise stays
true: `activity.py` holds no mutation capability. A new module,
`app/stopper.py`, owns the stop.

After each observer pass (every 30 s), for each workspace whose view is
`idle` with `remaining_seconds == 0`, and only when enforcement is on, the
stopper runs these checks in order. Any failed check means "do not stop
now"; the reason is logged and recorded once per change, not every pass.

1. **Policy.** The workspace is not `always_on`.
2. **Recent use.** `POST /v1/workspaces/{id}/touch` (already sent by
   `lib/connect.sh:92` before the session opens) resets that workspace's
   idle credit to zero. So a workspace someone is connecting to right now
   has a full timeout ahead of it. This is the coordination with
   connect/start that the ticket asks for.
3. **Fresh, uncached recheck.** Probe the workspace again, bypassing the
   5 s snapshot cache. Require all of:
   - exactly one running DevPod container for the workspace,
   - the same `(container id, StartedAt)` as the record that earned the
     idle credit,
   - a complete probe report inside the accepted time window,
   - every activity signal an integer `0`, and `t3_servers` an integer `0`.
4. **Stop.** `POST /containers/<full id>/stop?t=30` through the proxy.

One stop runs at a time, inside the observer loop, so a stop cannot overlap
the next sampling pass for that workspace.

Outcomes:

- Success (Docker answers 204, or 304 "already stopped"): history event
  `stop` with the idle seconds; the next pass reports state `stopped`.
- Failure (proxy denial, Docker error, timeout): history event
  `stop-failed` with a short reason; the workspace is not retried for 10
  minutes. Idle credit is kept.

Existing protections that continue to block a stop with no new code:
unknown, partial or stale probes; duplicate running containers; a gap of
more than 90 s between samples; a container restart; a policy change. A
catalog restart resets every countdown to zero, so no workspace is stopped
sooner than one full timeout after the catalog starts.

Residual risk, accepted: between the recheck and the stop there is a
window of a few milliseconds. A session opened in that window is dropped
and the user reconnects, which starts the workspace again. No data is at
risk; a stop sends SIGTERM and waits 30 s.

Detection limits carry over from the observation feature and are now
enforcing: a background job with no terminal, a residual IDE server
process and a bare DevPod process do not count as activity. A workspace
that must survive those needs `always_on`.

### 3. Enforcement switch

`Settings` gains `activity_enforce: bool = False` (`CATALOG_ACTIVITY_ENFORCE`
in `catalog.env`). Off is today's behaviour. Turning it on needs an explicit
owner go-ahead (see Rollout) and a catalog restart, which resets all
countdowns.

### 4. Proxy route (`catalog-service/proxy/dvw_docker_proxy.py`)

One route is added to the allowlist:

`POST /containers/<cid>/stop`

Accepted only when all hold, otherwise denied like any unknown route:

- `<cid>` is a full 64-character lowercase hex id. Names and short ids are
  refused for this route.
- The query is exactly one `t=<n>` with `n` an integer from 1 to 60.
- The request has no body.
- The proxy itself asks Docker for that container
  (`GET /containers/<cid>/json`) and finds the DevPod workspace label
  (`dev.containers.id`) on it. vossisrv also runs the Dokploy-managed
  production containers, so this check is what keeps a misbehaving catalog
  from stopping anything that is not a workspace.

Every allow and deny is logged with the container id, as for existing
routes. `start`, `restart`, `kill`, `pause`, `remove`, `update` and
`rename` stay denied, and tests assert each one.

The proxy is deployed separately from the catalog
(`deploy/dvw-docker-proxy.service`), so it must be updated before the
catalog's enforcement switch can do anything. No change to the catalog's
systemd sandbox is needed, because the stop travels over the proxy socket
it already uses.

### 5. API changes (`GET /v1/containers/activity`)

- `observation_only`: becomes a plain boolean. `true` when enforcement is
  off, `false` when on.
- `reasons`: gains the value `t3`.
- `signals`: gains `t3_servers`.
- `stop`: new, optional. The last automatic stop attempt for the workspace
  since the catalog started: `{"result": "stopped" | "failed", "at": <unix
  seconds>, "idle_seconds": <n>}`. Held in memory only. The durable record
  is the activity history file, which gains the events `stop` and
  `stop-failed`.

Compatibility: an older TUI rejects entries whose `observation_only` is not
`true` or whose reasons it does not know, and shows `activity unknown` for
them (`tui/dvw_tui/client.py:229-236`). That is a safe degradation, and
`dvw update` fixes it. The TUI and catalog ship from the same repository.

### 6. TUI (`tui/dvw_tui/render.py`, `client.py`)

Overview row, idle workspace: only `idle 47m`. Today it shows
`idle 47m · would stop in 13m`. Active stays the `◉` mark; other states
are unchanged apart from `always-on (t3)`.

Sidebar (inspect pane), in this order:

| Label | Example | Notes |
|---|---|---|
| activity | `idle 47m` | or the active reasons, `always-on (t3)`, `stopped` |
| stops in | `13m` | `now` at zero. Labelled `would stop in` while observation-only. Hidden unless idle. |
| mode | `automatic stop` | or `observation-only` |
| signals | `tmux 1 · terminals 3 · agents 2` | non-zero counts; `none` when all zero |
| idle since | `14:02 (47m ago)` | local time |
| observed | `14:49 (12s ago)` | local time |
| timeout | `60m` | |
| last stop | `auto-stopped 14:02 after 60m idle` | or `stop failed 14:02`. Only when `stop` is present. |

`parse_activity` accepts `observation_only` as a boolean, keeps `signals`
and `stop`, and accepts the `t3` reason.

## Components and repositories

| Change | Repository | Files |
|---|---|---|
| `t3_servers` in the probe | aiCodingBaseSetup | `bin/dvw-probe`, its tests |
| Exemption, stopper, switch, API | dvw | `catalog-service/app/{probe,activity,stopper,config,main,docker_inspect}.py`, `routers/workspaces.py` (touch resets credit) |
| Stop route | dvw | `catalog-service/proxy/dvw_docker_proxy.py`, `deploy/docker-proxy.md` |
| TUI | dvw | `tui/dvw_tui/{render,client}.py` |
| Docs | dvw | `README.md`, `catalog-service/README.md` |

## Testing

- **Probe:** `t3_servers` counts a `t3 serve` process, ignores other
  processes named `t3` and other `serve` commands, and is null when the
  `/proc` scan is incomplete.
- **Observer:** `t3_servers > 0` gives `always-on` with reason `t3`; null
  or missing gives `unknown`; `always_on` takes precedence; touch resets
  idle credit.
- **Stopper:** one test per refusal (enforcement off, always-on, T3,
  touched, two running containers, changed container id, changed
  `StartedAt`, partial probe, stale probe, any non-zero signal, any null
  signal), plus success, "already stopped", failure with 10 minute
  back-off, and "no stop within one timeout of catalog start".
- **Proxy:** the allow case, and a denial for each of: wrong method, short
  id, container name, missing `t`, `t` out of range, duplicate `t`, extra
  query key, non-empty body, container without the DevPod label, upstream
  inspect failure. Plus a denial for each sibling verb listed in section 4.
- **TUI:** render tests for the overview row and each sidebar line in
  observation-only and enforcing modes, and parser tests for the new
  fields including an old-shape entry.
- **Live:** gate 0, then the rollout steps below.

## Rollout

Each step is separately reversible. Step 5 is the only one that changes
what happens to a running workspace.

1. Gate 0 passes.
2. aiCodingBaseSetup PR with the probe field merges; the fleet is synced.
   The old catalog ignores the extra field (`extra="ignore"`).
3. dvw PR merges. Proxy and catalog are deployed with enforcement off.
4. Validate in observation mode for at least one working day: T3
   workspaces show `always-on (t3)`, no workspace sits at `unknown`, and
   countdowns behave during normal tmux, Cursor and T3 use.
5. Owner gives an explicit go-ahead. Set `CATALOG_ACTIVITY_ENFORCE=true`
   and restart the catalog.
6. Supervised first stop: set `idle_timeout_minutes` to 5 on one idle
   workspace, watch it stop, reconnect with `dvw <id>`, restore the
   timeout.

Rollback at any point: set `CATALOG_ACTIVITY_ENFORCE=false` and restart the
catalog. Stopped workspaces start again on connect.

## Open points for review

- Whether touch-resets-credit is enough coordination with connect, or the
  stopper should also refuse when `last_used_at` is within the last few
  minutes regardless of credit.
- Whether the in-memory `stop` record should instead be read back from the
  history file so the "last stop" line survives a catalog restart.
- Whether `always_on` needs a `dvw` command now that the flag has real
  consequences, or the PATCH field is enough for the few workspaces that
  need it.
