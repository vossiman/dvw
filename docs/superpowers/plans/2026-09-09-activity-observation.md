# Workspace activity observation implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent probe and TUI tasks; integrate the catalogue centrally.

**Goal:** Show live coding activity and a shared 60-minute hypothetical stop countdown without stopping containers.

**Architecture:** The existing read-only in-container probe emits bounded activity signals. A single catalogue background observer samples every 30 seconds and owns idle timing; clients display its cached result. Observation state resets after service restarts, container restarts, failed samples, or sampling gaps rather than crediting unobserved idle time.

**Tech Stack:** Python probe, FastAPI/Pydantic catalogue, Textual TUI.

**Spec:** User-approved design in this session: tmux (attached or detached), live Cursor/VS Code connections, interactive terminals and coding agents keep workspaces active; persistent server processes do not. Always-on overrides and configurable timeout. Unknown activity never produces an idle countdown. Observation only.

## Global constraints

- No stop/delete capability, proxy permission widening, deployment, or main-branch changes.
- Default timeout 3600 seconds; positive per-workspace override and always_on flag via existing PATCH API.
- Preserve schema-1 probe compatibility; an old probe yields unknown.
- Process names alone do not identify Cursor; use executable provenance and live socket ownership. Bare devpod is not proof of active use.
- Never expose command arguments or environment values.

## Tasks

- [x] Probe: extend `bin/dvw-probe` in the blueprint worktree with nullable counts `activity.{tmux_sessions,terminals,cursor_connections,vscode_connections}`. Test absent vs failed tmux, connected vs residual IDE processes, terminal lifetime, inaccessible metadata, bounded scans. Run blueprint bats suite.
- [x] Catalogue: add validated probe extension, read-only `DockerInspector.activity_many(ids)` collection, `ActivityObserver` state machine and periodic lifecycle task, `/containers/activity` cached API, and workspace `always_on`/`idle_timeout_minutes` settings. Test unknown/partial/missing probes, duplicates, container identity/start changes, monotonic countdown, interrupted observations, overrides, expiry, background lifecycle and API validation.
- [x] TUI: fetch cached activity, tolerate old services, render parent-row summaries and inspect details without changing tmux routing. Test client parsing, all states and details; run full TUI suite.
- [ ] Integration: run catalogue/TUI/bats checks, review both worktrees, document rollout and limitations, commit and open dependent PRs. Do not merge or deploy.

## Interface

`GET /v1/containers/activity` returns a list with `workspace_id`, `state` (active/idle/always-on/unknown/stopped), `reasons` (tmux/cursor/vscode/terminal/agent), nullable epoch `observed_at` and `idle_since`, nullable integer `idle_seconds` and `remaining_seconds`, `timeout_seconds`, `observation_only: true`, and nullable-count `signals`. This endpoint never probes on demand. Missing or stale samples return unknown and clear the countdown.

## Review ledger

Probe -> catalogue: additive nullable counts, all absence decisions require complete evidence. Catalogue -> TUI: shared response above, no client inference. Tasks own disjoint directories. Ruling: sample interval 30s; stale/gap threshold 90s; resets on process restart are conservative and avoid persisting misleading idle credit. No policy evaluation while TUI closed depends on client calls.

Review: independent whole-feature review identified slow-batch sample freshness; fixed by carrying batch-start monotonic time and rejecting aged samples. Scoped re-review found no blockers. Regressions cover both delayed-sample rejection and expiry from collection time. Probe commit: 23662bcd254104f31c515b6bd9a72fba25fe5316.

Validation: catalogue full suite 298 passed, then 22 focused activity tests passed with the additional delayed-expiry regression; TUI full suite 235 passed; dvw bats 587 passed. Blueprint full suite 875 cases, seven environment skips, exit 0. An unrelated orphan push-watch test sleep was cleaned up and filed as DVW-17.
