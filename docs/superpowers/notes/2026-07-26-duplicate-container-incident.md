# Duplicate container siblings — incident findings (2026-07-26)

Two workspaces silently acquired a second running container. One of them
became unreachable; `dvw doctor` reported "✓ all checks passed" throughout.

## Symptom

```
roleplaygame-git-develop: multiple containers and none has a live tmux `work`
session — refusing to guess
```

## What was actually true

| workspace | containers | gap between them |
|---|---|---|
| `roleplaygame-git-develop` | 2 running | **5.9 s** (07:36:27.98 → 07:36:33.83) |
| `handsfree-git-main` | 2 running | **2.5 ms** (07:37:50.312251 → 07:37:50.314788) |

Seven running containers mounted a `/workspaces/<id>` path while only five
workspaces existed. `dvw doctor` reported `alive=5` — the count was of
*workspaces*, so the duplicates were invisible.

Only roleplaygame was actually broken. handsfree had a `work` session in
exactly one sibling, so the tie-break resolved and connect worked; nobody
noticed it was duplicated.

## Telling the real container from the dud

Two signals, both decisive:

| | real | dud |
|---|---|---|
| `/workspaces` owner | `codespace:codespace` | **`root:root`** — `setup-user` never ran |
| tmux | `work` session present | `tmux: executable file not found` |

The dud is created and abandoned before provisioning finishes, so it never
gets the devcontainer's user setup. Both siblings share the *same* host bind
mount, so **removing the dud loses nothing** — workspace content lives in
`~/.devpod/agent/contexts/default/workspaces/<id>/content` on the host.

## Why the tooling didn't show it

1. **Orphan detection can't apply.** An orphan is a container whose workspace
   id is *absent from the catalog*. Siblings belong to a known workspace, so
   they're not orphans by definition.
2. **Bulk status discarded the evidence.** `status_many` explicitly preferred
   "a running container if duplicates share a destination", then reported the
   arbitrary winner as plain `running`. The duplicate was known and thrown away.
3. **Nothing was logged.** dvw had no action log of any kind, so "did something
   run `devpod up` twice?" was unanswerable after the fact.

## Hypotheses tested

| hypothesis | verdict |
|---|---|
| Power outage / reboot lost the containers | **Dead.** `uptime -s` = 2026-07-19; the box had been up a week. |
| `AGENT_PATH=/tmp/...` wiped on boot lost agent state | **Dead.** It is a bare 85 MB *binary*; all state is under `/home/vossi/.devpod/agent/`. And `/tmp` had not been cleared since Jul 19. |
| Concurrent `ssh <id>.devpod` double-creates via ProxyCommand | **Dead — tested.** Removed a container, fired two parallel `ssh`; exactly one container resulted. The client's `ControlMaster` collapses the second connection (`ControlSocket ... already exists, disabling multiplexing`). |
| Stopped containers slip past the `devpod up` wipe guard | **Real but not this.** `_dvw_provider_has_container` only counts *running* containers, so a stopped one doesn't trip the guard. No stopped containers existed during the incident. |
| devcontainer config drift triggers a recreate | **Untested, current leading theory.** `devpod up` recreates when the live config differs from `lastDevContainerConfig` in `workspace.json`; that removes the old container (matching the observed "absent") and builds a new one. |

**The root cause remains unidentified.** A 2.5 ms gap is too tight for two
independent invocations each doing real work — it suggests one orchestrator
emitting two creates rather than two racers. The action log added alongside this
note exists to answer that on the next occurrence.

## Recovery (no deletion needed to get unblocked)

```bash
# 1. identify the siblings
curl -sS --unix-socket /run/dvw-catalog/catalog.sock \
  http://localhost/v1/workspaces/<id>/siblings | jq

# 2. break the tie — give the REAL one a `work` session
docker exec <live-id> tmux new-session -d -s work

# 3. only then, after checking it, remove the dud
docker rm -f <dud-id>
```

Step 2 alone restores connect. Removal is never required urgently.

## Verifying no duplicates exist

`dvw doctor` now reports this directly. Without a deployed service, the same
computation by hand on the provider:

```bash
docker ps -a --format '{{.ID}}\t{{.State}}\t{{.Names}}' | while IFS=$'\t' read -r id state name; do
  dest=$(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$id" 2>/dev/null \
         | grep -m1 '^/workspaces/')
  [ -n "$dest" ] && printf '%s\t%s\t%s\n' "$dest" "$state" "$id"
done | sort | cut -f1 | uniq -c | awk '$1>1'
```

## Incidental findings

- **The start path is safe.** A container created 2026-07-14 was running after
  the 2026-07-19 boot with `RestartPolicy: no` — i.e. `docker start`ed, not
  recreated. Stopped containers are reused; only the *create* path can duplicate.
- **`dvw status` and connect could disagree.** Status showed `● running` (an
  arbitrary sibling) while connect refused the same workspace as ambiguous.
- Container timestamps are UTC; the provider host is UTC+2. Compare carefully.
