# Automatic workspace stop after idle: design

Date: 2026-10-03. Ticket: DVW-18. Status: draft, revised after review rounds 1
and 2 (Codex `gpt-6-astra`, 2026-10-03).

## Goal

The catalog already measures how long each workspace has been idle
(`catalog-service/app/activity.py`), but only reports it. This design makes
the catalog stop a workspace container once it has accumulated its timeout
in verified idle time, and tidies how the TUI shows idle state.

Success means:

- An idle workspace is stopped after its timeout (default 60 minutes) and
  starts again on the next `dvw <id>`.
- A workspace with a live session, a running agent or a T3 server that the
  probe can see, or with an `always_on` flag, is never stopped. What the
  probe cannot see is listed under "Detection limits".
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

What the code says should happen: the catalog resolves only running
containers, so a stopped workspace answers "no container" and
`lib/connect.sh:76-79` runs an explicit `devpod up` before anything touches
the `<id>.devpod` alias. That answer is cached for 8 s
(`resolve_cache_ttl`, `app/deps.py:82-95`), so a reconnect inside that
window takes the other branch: the alias probe fails and the provider is
asked directly (`connect.sh:80-90`).

On vossisrv, with an idle workspace nobody needs (`dataenv-git-devpod`).
Record the container id and a marker file in the workspace first.

1. `docker stop -t 10 <container>`.
2. Confirm the catalog reports `liveness: stopped` and the activity state
   `stopped`.
3. Confirm the container stays stopped for ten minutes (no restart policy
   or DevPod daemon brings it back).
4. `dvw dataenv-git-devpod` from a client. It must start the same
   container (same container id, no twin, no recreate), open the session,
   and show the marker file.
5. Stop it again and reconnect within 5 seconds, to exercise the cached
   "still running" answer.
5a. Start `docker stop -t 10` and run `dvw dataenv-git-devpod` while the
   stop is still in progress. This shows what an unprotected client does
   today, and is the behaviour the in-flight wait in section 2 replaces.
6. Stop it again and run `dvw start dataenv-git-devpod`.
7. Stop it again and open it with `--cursor`.
8. Stop it again and connect from a second client machine, whose local
   DevPod state is older.
9. After each restart, confirm what the container needs at boot came back
   (the boot sync ran, the tmux `work` session can be created).

### Result (run by the owner, 2026-10-03, `dataenv-git-devpod`)

Passed. Decision 3 stands.

| Step | Observed |
|---|---|
| 1 | `docker stop -t 10` returned in 0.86 s, exit code 0. Restart policy `no`. |
| 2 | Catalog status `liveness: stopped`, activity state `stopped`. `GET /v1/workspaces/<id>/container` returns `container_id: null`. |
| 3 | Still exited after ten minutes, same `StartedAt`. |
| 4 | Client `devpod status` said `Stopped`. `dvw <id>` printed `starting`, the session opened about 14 s later. Same container id, new `StartedAt`, both marker files present (the one in the container filesystem proves a restart, not a recreate), exactly one container on the workspace mount. |
| 5 | Stop, then connect at once: took the explicit start path and connected in about 4 s. |
| 5a | Stop in the background, connect 0.3 s later: connected normally. The stop finished before dvw reached its liveness check, so the in-flight window was not actually hit. It is under a second for an idle container. |
| 6 | `dvw start` reported `state=stopped`, started it, and the following connect worked. |
| 9 | tmux `work` was created on each start. |

Not run: step 7 (Cursor) and step 8 (second client). DevPod prints
`Creating devcontainer...` on every start, including a plain restart, so
that line is not evidence of a recreate.

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
`null` when it was not. Like the existing counters it sees only processes
owned by the probe's own user (`bin/dvw-probe:230`, `:361`), which is the
user the managed launcher runs T3 as (`lib/t3-supervise:33`).

In the catalog, `ProbeActivity` (`app/probe.py`) gains
`t3_servers: int | None`. It is not an activity signal. It is an exemption:

- `t3_servers > 0`: state `always-on`, with the reason `t3`. Entering this
  state clears any idle credit, like any other non-idle state.
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

The observer stays the single owner of idle credit, and `activity.py`
still holds no mutation capability. A new module, `app/stopper.py`, owns
the stop. It never keeps its own copy of the countdown.

**Idle credit.** Credit is accumulated verified idle time, not strictly
uninterrupted time: today's observer keeps earned credit across one
unknown sample and does not credit the gap
(`activity.py:106-111`, `tests/test_activity.py:216`). That rule stays. A
second unknown in a row, any activity, a container restart, a policy change
or a gap over 90 s resets it, as today.

**Touch.** `POST /v1/workspaces/{id}/touch` resets that workspace's credit
to zero in the observer. `lib/connect.sh:92` already sends it before the
session opens. Two client changes make it cover every entry path: the
touch moves to the top of `_connect_ssh` (before the start checks, not
after; `_connect_cursor` already sends it first, `lib/connect.sh:367`),
and `cmd_start` sends it too (it sends none today,
`lib/commands.sh:135`).

**Stop sequence.** After each observer pass (every 30 s), for each
workspace whose view is `idle` with `remaining_seconds == 0`, and only when
enforcement is on and the workspace is not `always_on`:

1. **Recheck.** Take a fresh sample of that workspace, bypassing the 5 s
   snapshot cache, and apply it with the observer's own transition logic
   as a single-record update. `ActivityObserver.update` replaces the whole
   record set on every call (`activity.py:72`, `:125`), so it cannot be
   called with one sample: that would wipe or blank every other
   workspace's countdown. The per-record transition is factored out so a
   full pass and a recheck share it; only a full pass prunes records. The
   recheck is therefore an ordinary observation: if it
   shows activity, a T3 server, an unknown, a second container or a
   restarted container, the observer's existing rules clear or carry the
   credit. There is no separate "refused, try again next pass" state that
   could stop on stale credit.
2. **Revalidate.** The recheck runs in a thread while the event loop keeps
   serving requests, so a touch can arrive during it. After it returns, read
   the workspace's record again and require: state `idle`,
   `remaining_seconds == 0`, the same idle start as before the recheck, the
   same `(container id, StartedAt)`, and policy unchanged. Steps 2 and 3
   run without yielding to the event loop in between, so no touch can land
   between the final check and the dispatch.
3. **Stop.** Mark the workspace as "stop in flight", recording the target
   `(container id, StartedAt)`, in the same step that hands the call to
   the worker thread. Then `POST /containers/<full id>/stop?t=10` through
   the proxy, with
   a 25 s client deadline for this call only. The general Docker client
   timeout stays at 10 s (`config.py:68`); the proxy's 30 s upstream
   timeout (`dvw_docker_proxy.py:558`) already exceeds the grace period.
4. **Invalidate.** Drop the workspace's entries from the resolve cache and
   the snapshot cache, so a reconnect straight after does not read "still
   running".

One stop runs at a time, inside the observer loop.

A touch that arrives after the stop is dispatched cannot cancel it, and
the container keeps answering as "running" for up to 10 s while it shuts
down. Left alone, `dvw start` would report "already running"
(`lib/commands.sh:146-149`) and connect would open a session into a
container that is about to die. So while a stop is in flight, the touch
request does not return until the stop has finished or been reconciled
(bounded by the 25 s deadline). The client then runs its normal liveness
checks against the settled state and starts the workspace. For this to
hold, the client's touch call must wait at least that long, and a touch
that fails or times out during connect or start is reported to the user
instead of being ignored as it is today (`lib/connect.sh:92`).

Outcomes:

- **Stopped** (Docker answers 204, or 304 "already stopped"): history event
  `stop` with the idle seconds.
- **Failed** (proxy denial, Docker error status): history event
  `stop-failed` with a short reason. No retry for 10 minutes.
- **Uncertain** (deadline passed or connection lost): nothing is assumed.
  The stopper inspects the recorded target container by id (a route the
  proxy already allows). The ordinary activity sample is not enough,
  because it only looks at running containers and keeps no identity for a
  stopped one (`docker_inspect.py:570-580`).
  - Target not running: record `stop`.
  - Target gone, or running with a different `StartedAt`: the stop worked
    and something started the workspace again. Record `stop`.
  - Target running with the same `StartedAt`: record `stop-failed` and
    apply the 10 minute back-off.
  - Inspect unavailable or ambiguous: the stop stays in flight. No new
    stop is attempted for that workspace until it is resolved.

Existing protections that continue to block a stop with no new code:
unknown, partial or stale probes; duplicate running containers; a gap of
more than 90 s between samples; a container restart; a policy change. A
catalog restart resets every countdown to zero, so no workspace is stopped
sooner than one full timeout after the catalog starts. Countdowns are never
restored from the history file.

**Detection limits.** These are inherited from the observation feature
and become enforcing. The guarantee in "Goal" covers only what the probe
measures:

- Processes owned by another user in the container are not seen
  (`bin/dvw-probe:230`, `:361`).
- Agents are recognised from a fixed list: `claude`, `codex`,
  `cursor-agent`, `opencode` (`bin/dvw-probe:26`).
- IDE connections are detected from TCP sockets only
  (`bin/dvw-probe:425`).
- A background job with no terminal, a residual IDE server process and a
  bare DevPod process do not count as activity.

A workspace whose real use falls outside these needs `always_on`. Rollout
step 4 checks this against real use before enforcement; whether any
workspace on the fleet is exposed today is not verified.

What a stop costs: the container gets SIGTERM and 10 s, then SIGKILL.
Files on the workspace mount are untouched. Anything held only in a
process is lost, exactly as with a manual `dvw stop`.

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
- The raw query string matches `t=<n>` exactly, with `n` an integer from 1
  to 20, checked with an anchored pattern against the undecoded string. The
  proxy forwards the original request target today
  (`dvw_docker_proxy.py:333-336`); for this route it rebuilds a canonical
  one (`/containers/<cid>/stop?t=<n>`) instead of passing the client's
  through.
- The request has no body.
- The proxy itself asks Docker for that container
  (`GET /containers/<cid>/json`) and finds the DevPod workspace label
  (`dev.containers.id`) on it. vossisrv also runs the Dokploy-managed
  production containers, so this check is what keeps a misbehaving catalog
  from stopping anything that is not a workspace. A malformed or failed
  inspect response denies the stop.

Every allow and deny is logged with the container id, as for existing
routes. `start`, `restart`, `kill`, `pause`, `remove`, `update` and
`rename` stay denied, and tests assert each one.

What the route does not limit: a compromised catalog could stop any
labelled workspace container, including an active or exempt one, and the
enforcement switch does not revoke the route. The damage is bounded to
stopping workspaces, which restart on connect. Removing the capability
means deploying the previous proxy.

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
them (`tui/dvw_tui/client.py:229-236`). But its sidebar also prints
`observation-only; no automatic stops` unconditionally
(`tui/dvw_tui/render.py:181`), which would be false once enforcement is on.
So every client machine must run the new TUI before enforcement is switched
on (rollout step 5). While enforcement is off, old and new clients are both
correct.

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
and `stop`, and accepts the `t3` reason. When an entry cannot be parsed,
the `mode` line reads `unknown`, never `observation-only`.

The sidebar skips the activity block for stopped and absent workspaces
today (`tui/dvw_tui/screens/main.py:378-379`). That changes: a stopped
workspace shows `activity`, `mode`, `timeout` and `last stop`.

## Components and repositories

| Change | Repository | Files |
|---|---|---|
| `t3_servers` in the probe | aiCodingBaseSetup | `bin/dvw-probe`, its tests |
| Exemption, stopper, switch, API | dvw | `catalog-service/app/{probe,activity,stopper,config,main,docker_inspect,deps}.py`, `routers/workspaces.py` (touch resets credit) |
| Touch on every entry path | dvw | `lib/connect.sh`, `lib/commands.sh` |
| Stop route | dvw | `catalog-service/proxy/dvw_docker_proxy.py`, `deploy/docker-proxy.md` |
| TUI | dvw | `tui/dvw_tui/{render,client}.py`, `tui/dvw_tui/screens/main.py` |
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
  Interleavings: a touch during the recheck cancels the stop; mature credit,
  then a recheck that sees an agent or T3, then quiet, needs a full new
  timeout; a stop whose response is lost is reconciled on the next pass in
  both directions, including a target that was restarted or replaced
  before reconciliation and an inspect that stays unavailable; a recheck
  of one workspace leaves every other workspace's credit untouched; a
  touch during an in-flight stop returns only after it settles; the caches
  are invalidated after a stop; the catalog shutting down mid-stop leaves
  no false record.
- **Client:** `_connect_ssh`, `_connect_cursor` and `cmd_start` each send
  the touch before their start checks, wait for it, and report a failed
  touch.
- **Proxy:** the allow case, and a denial for each of: wrong method, short
  id, container name, missing `t`, blank `t`, `t` out of range, duplicate
  `t`, extra query key, percent-encoded key or value, non-empty body,
  container without the DevPod label, upstream inspect failure, malformed
  inspect response. The forwarded target is the rebuilt canonical one. Plus a denial for each sibling verb listed in section 4.
- **TUI:** render tests for the overview row and each sidebar line in
  observation-only and enforcing modes, parser tests for the new fields
  including an old-shape entry, and a screen-level test that a stopped
  workspace shows its `last stop` line.
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
   countdowns behave during normal tmux, Cursor and T3 use. For each kind
   of real use on the fleet, confirm the workspace reads `active` while it
   is in use; set `always_on` (via `PATCH /v1/workspaces/{id}`) on any
   workspace whose use the probe does not see, and note it in the README.
5. Every client machine runs the new TUI (`dvw update`). Owner gives an
   explicit go-ahead. Set `CATALOG_ACTIVITY_ENFORCE=true` and restart the
   catalog.
6. Supervised first stop: set `idle_timeout_minutes` to 5 on one idle
   workspace, watch it stop, reconnect with `dvw <id>`, restore the
   timeout. Repeat once connecting during the stop itself, and confirm the
   client waits and then starts the workspace.

Rollback at any point: set `CATALOG_ACTIVITY_ENFORCE=false` and restart the
catalog. Stopped workspaces start again on connect.

## Implementation notes

The stop call's deadline is the Docker client timeout plus the grace (20 s by
default), not a dedicated 25 s, and the touch waits that long plus 5 s.

The client touch is the first statement of `cmd_connect` (before any
container-state read), not of `_connect_ssh`. `cmd_start` touches first as
designed.

The sidebar shows the activity block for a stopped workspace only when an
automatic stop is on record. A manually stopped workspace looks as before.

## Review record

Round 1 (Codex `gpt-6-astra`, high effort, 2026-10-03): eight findings,
all confirmed against the code and folded in above. The three points left
open in the first draft are settled as the reviewer recommended:

- **Connect coordination:** touch alone was not enough. The design now
  uses an early touch on every entry path plus revalidation after the
  recheck.
- **"Last stop" across catalog restarts:** stays in memory. The history
  file is the durable record.
- **A `dvw` command for `always_on`:** not needed for this change. The
  PATCH field is enough, with the exemption check written into rollout
  step 4.

Round 2 (same reviewer, final): one P1 and two P2, all confirmed and
folded in. A connect or start during an in-flight stop now waits for it;
the recheck is a single-record update instead of a call to `update`; an
uncertain stop is reconciled against the recorded target container. There
is no third round: anything further goes to the implementation plan and
its tests.
