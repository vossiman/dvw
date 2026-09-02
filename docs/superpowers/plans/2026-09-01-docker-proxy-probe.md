# Docker Proxy and In-Container Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tecnativa socket proxy with a purpose-built, allowlisting unix-socket proxy so the catalog service can never reach host root, and replace the three tmux execs with one `dvw-probe` exec that also reports agents, git and cgroup facts.

**Architecture:** `dvw-docker-proxy` (stdlib Python, systemd socket-activated, user `dvw-proxy`) sits between the catalog and `docker.sock` with an exact route table; exec is limited to `Cmd == ["dvw-probe"]` (plus a transitional tmux form). `dvw-probe` (aicoding `bin/`) prints one JSON document per exec. The catalog parses it as untrusted input, memoizes it per request, and falls back to tmux when the probe is missing. The TUI inspect pane gains agents and git lines. A docker-in-docker harness exercises the real path.

**Tech Stack:** Python 3.12 stdlib (proxy, probe; the proxy runs with `/usr/bin/python3` on Ubuntu 24.04), FastAPI + docker-py 7 (catalog), Textual (TUI), bash + bats (aicoding tests, e2e), pytest (catalog, tui, proxy), systemd socket activation, `docker:dind`.

**Spec:** `docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md` (same worktree). Read it first; this plan argues from it.

## Global Constraints

- The proxy and the probe use only the Python standard library. The proxy is executed as `/usr/bin/python3 /opt/dvw-catalog/proxy/dvw_docker_proxy.py`; it must run on Python 3.12 (no 3.13+ syntax or modules). The dev container has 3.14, so avoid anything not in 3.12.
- Em dashes (the long dash character) are forbidden in any generated text: code, comments, commit messages, docs, test names. Use a comma, colon, or two sentences.
- Proxy route table, exec validation rules, exec-id TTL (60 s, capacity 256), request limits (header block 16 KiB, body 64 KiB, client response cap 1 MiB) and the 403/400 bodies are exactly as the spec states.
- Probe: no arguments, always exit 0 once running, 3 s total budget, schema version 1, sections `tmux`, `agents`, `git`, `cgroup`, plus `schema`, `ts`, `partial`.
- Catalog: `ProbeReport` has `extra="ignore"`, list caps (`sessions` 64, `windows` 256, `agents` 64), string cap 512, output over 256 KiB discarded; exit codes 126 and 127 mean "probe missing" and trigger the tmux fallback.
- Two repos, two worktrees, two PRs. Group A commits land on aicoding branch `feat/dvw-probe`; Group B commits land on dvw branch `feat/docker-proxy-probe`. Never commit to `main` in either repo.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
  ```
- Test commands (run from the paths shown):
  - catalog-service: `cd catalog-service && uv run --extra dev pytest -q` (the `dev` extra carries pytest and httpx).
  - tui: `cd tui && uv run --group dev pytest -q`.
  - dvw bats: `tests/bats/run.sh` from the dvw worktree root (all files), or `bats tests/bats/<file>.bats` with `DVW_ROOT="$PWD"` exported.
  - aicoding bats: `tests/bats/run.sh <basename>` from the aicoding worktree root, never bare `bats`.

## Worktrees

- Group A: `/workspaces/devmachine/devpod/aicoding/.claude/worktrees/feat/dvw-probe`, created with
  `git -C /workspaces/devmachine/devpod/aicoding worktree add .claude/worktrees/feat/dvw-probe -b feat/dvw-probe origin/main` (fetch first). Referred to below as `$AIC`.
- Group B: `/workspaces/devmachine/devpod/dvw/.claude/worktrees/feat/docker-proxy-probe` (exists, branch `feat/docker-proxy-probe`). Referred to below as `$DVW`.

## File Structure

Group A (aicoding):
- Create `bin/dvw-probe`: the probe script. One `main()`, one function per collector, a `_deadline` helper.
- Create `tests/bats/dvw-probe.bats`: behaviour tests with fake `tmux`/`git` on PATH and fixture `/proc` and cgroup trees.
- Modify `lib/provision-integrations.sh`: add `install_dvw_probe_symlink()` after `install_agent_notify_symlink()` (line 64-71).
- Modify `install.sh:123`: call `install_dvw_probe_symlink` after `install_agent_notify_symlink`.
- Modify `tests/bats/install.bats`: one test after the agent-notify symlink test (line 185-190).

Group B (dvw):
- Create `catalog-service/proxy/__init__.py` (empty) and `catalog-service/proxy/dvw_docker_proxy.py`: request parsing, route table, exec validation, exec registry, relay, socket-activation `main()`.
- Create `catalog-service/tests/test_proxy.py`: fake upstream + proxy-in-thread tests.
- Create `catalog-service/app/probe.py`: `ProbeReport` and friends, `run_probe`.
- Create `catalog-service/tests/test_probe.py`.
- Modify `catalog-service/app/docker_inspect.py`: snapshot memo, probe-first, tmux fallback; `inspect()` image field without `/images`.
- Modify `catalog-service/app/models.py:232-254`: `AgentProc`, `GitState`, new `ContainerInspect` fields.
- Modify `catalog-service/tests/test_resolver.py` FakeContainer: probe support. Modify `catalog-service/tests/conftest.py` FakeInspector only if a signature changes (it does not).
- Modify `tui/dvw_tui/render.py`: `agents_line`, `git_line`, two new pairs in `inspect_lines`. Tests in `tui/tests/test_render.py`.
- Create `catalog-service/deploy/dvw-docker-proxy.socket`, `catalog-service/deploy/dvw-docker-proxy.service`, `catalog-service/deploy/docker-proxy.md`.
- Modify `catalog-service/deploy/host-install.sh`, `host-update.sh`, `dvw-catalog.service:66`, `catalog.env.example:8-10`; delete `docker-proxy.compose.yml`, `docker-socket-proxy.md`.
- Create `tests/e2e/dind.sh`, `tests/e2e/workspace.Dockerfile`, `tests/bats/e2e-dind.bats`.

---

## Group A: aicoding

### Task 1: `bin/dvw-probe` with bats tests

**Files:**
- Create: `$AIC/bin/dvw-probe`
- Create: `$AIC/tests/bats/dvw-probe.bats`

**Interfaces:**
- Produces: executable `bin/dvw-probe`, stdout = one JSON object with keys `schema` (int 1), `ts` (int epoch), `partial` (bool), `tmux` (object or null), `agents` (list or null), `git` (object or null), `cgroup` (object or null). Exit code 0 always. Env overrides `DVW_PROBE_PROC`, `DVW_PROBE_CGROUP`, `DVW_PROBE_WORKSPACE`, `DVW_PROBE_BUDGET` (seconds, default 3).

- [ ] **Step 1: Create the worktree**

```bash
git -C /workspaces/devmachine/devpod/aicoding fetch -q origin
git -C /workspaces/devmachine/devpod/aicoding worktree add .claude/worktrees/feat/dvw-probe -b feat/dvw-probe origin/main
cd /workspaces/devmachine/devpod/aicoding/.claude/worktrees/feat/dvw-probe
```

- [ ] **Step 2: Write the failing bats tests**

`$AIC/tests/bats/dvw-probe.bats`:

```bash
#!/usr/bin/env bats
# bin/dvw-probe: one exec, one JSON document describing the container from
# the inside (tmux, agents, git, cgroup). Everything external is faked: tmux
# and git are stubs on PATH, /proc and /sys/fs/cgroup are fixture trees.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  PROBE="$BLUEPRINT_ROOT/bin/dvw-probe"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/proc" "$TMPDIR/cgroup" "$TMPDIR/ws"
  export PATH="$TMPDIR/stubs:$PATH"
  export DVW_PROBE_PROC="$TMPDIR/proc"
  export DVW_PROBE_CGROUP="$TMPDIR/cgroup"
  export DVW_PROBE_WORKSPACE="$TMPDIR/ws"

  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
case "$*" in
  *list-sessions*) printf 'work\t1\t1756799990\nother\t0\t1756700000\n' ;;
  *list-windows*)  printf '@7\tclaude\t1\t1756799990\t\tnode\n@8\tshell\t0\t1756790000\t1756795000\tbash\n' ;;
esac
exit "${TMUX_STUB_EXIT:-0}"
STUB
  cat > "$TMPDIR/stubs/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"--abbrev-ref HEAD"*) echo "feat/x" ;;
  *"--short HEAD"*)      echo "abc1234" ;;
  *"status --porcelain"*) printf ' M file\n' ;;
  *"rev-list --left-right --count"*) printf '2\t0\n' ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/tmux" "$TMPDIR/stubs/git"

  # cgroup v2 fixture
  echo 1234 > "$TMPDIR/cgroup/memory.current"
  echo 8589934592 > "$TMPDIR/cgroup/memory.max"
  printf 'usage_usec 123456\nuser_usec 100\n' > "$TMPDIR/cgroup/cpu.stat"
  echo 42 > "$TMPDIR/cgroup/pids.current"

  # /proc fixture: pid 4242 is claude, pid 77 is bash (ignored)
  mkdir -p "$TMPDIR/proc/4242" "$TMPDIR/proc/77"
  echo claude > "$TMPDIR/proc/4242/comm"
  printf 'claude\0--dangerously\0' > "$TMPDIR/proc/4242/cmdline"
  printf '4242 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 500 0 0\n' > "$TMPDIR/proc/4242/stat"
  ln -s "$TMPDIR/ws" "$TMPDIR/proc/4242/cwd"
  echo bash > "$TMPDIR/proc/77/comm"
  printf 'bash\0' > "$TMPDIR/proc/77/cmdline"
  printf '77 (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' > "$TMPDIR/proc/77/stat"
  ln -s / "$TMPDIR/proc/77/cwd"
  printf 'btime 1756700000\n' > "$TMPDIR/proc/stat"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

jq_probe() { "$PROBE" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

@test "emits valid JSON with schema 1 and exit 0" {
  run "$PROBE"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')" = "1" ]
}

@test "tmux section carries sessions and work windows with waiting_since" {
  [ "$(jq_probe 'd["tmux"]["sessions"][0]["name"]')" = "work" ]
  [ "$(jq_probe 'd["tmux"]["sessions"][0]["attached"]')" = "1" ]
  [ "$(jq_probe 'd["tmux"]["windows"][0]["id"]')" = "@7" ]
  [ "$(jq_probe 'd["tmux"]["windows"][0]["waiting_since"]')" = "None" ]
  [ "$(jq_probe 'd["tmux"]["windows"][1]["waiting_since"]')" = "1756795000" ]
  [ "$(jq_probe 'd["tmux"]["windows"][1]["command"]')" = "bash" ]
}

@test "agents lists claude with pid, cwd and a start epoch, ignores bash" {
  [ "$(jq_probe 'len(d["agents"])')" = "1" ]
  [ "$(jq_probe 'd["agents"][0]["cli"]')" = "claude" ]
  [ "$(jq_probe 'd["agents"][0]["pid"]')" = "4242" ]
  [ "$(jq_probe 'd["agents"][0]["cwd"]')" = "$TMPDIR/ws" ]
  # starttime 500 ticks at 100 Hz = 5 s after btime
  [ "$(jq_probe 'd["agents"][0]["started"]')" = "1756700005" ]
}

@test "git section reports branch, head, dirty, ahead and behind" {
  [ "$(jq_probe 'd["git"]["branch"]')" = "feat/x" ]
  [ "$(jq_probe 'd["git"]["head"]')" = "abc1234" ]
  [ "$(jq_probe 'd["git"]["dirty"]')" = "True" ]
  [ "$(jq_probe 'd["git"]["ahead"]')" = "2" ]
  [ "$(jq_probe 'd["git"]["behind"]')" = "0" ]
}

@test "cgroup section reads memory, cpu and pids" {
  [ "$(jq_probe 'd["cgroup"]["mem_current"]')" = "1234" ]
  [ "$(jq_probe 'd["cgroup"]["mem_max"]')" = "8589934592" ]
  [ "$(jq_probe 'd["cgroup"]["cpu_usec"]')" = "123456" ]
  [ "$(jq_probe 'd["cgroup"]["nr_procs"]')" = "42" ]
}

@test "memory.max of 'max' becomes null" {
  echo max > "$TMPDIR/cgroup/memory.max"
  [ "$(jq_probe 'd["cgroup"]["mem_max"]')" = "None" ]
}

@test "missing tmux gives tmux null, still exit 0 and not partial" {
  rm "$TMPDIR/stubs/tmux"
  run "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tmux"], d["partial"])')" = "None False" ]
}

@test "tmux failing exit code gives tmux null" {
  export TMUX_STUB_EXIT=1
  [ "$(jq_probe 'd["tmux"]')" = "None" ]
}

@test "no workspace dir gives git null" {
  export DVW_PROBE_WORKSPACE="$TMPDIR/does-not-exist"
  [ "$(jq_probe 'd["git"]')" = "None" ]
}

@test "a hanging tmux is cut off: tmux null, partial true, exit 0" {
  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
sleep 10
STUB
  chmod +x "$TMPDIR/stubs/tmux"
  export DVW_PROBE_BUDGET=1
  run "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tmux"], d["partial"], d["cgroup"]["nr_procs"])')" = "None True 42" ]
}

@test "refuses arguments with exit 0 and an error object" {
  run "$PROBE" --anything
  [ "$status" -eq 0 ]
  [[ "$output" == *'"error"'* ]]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/bats/run.sh dvw-probe`
Expected: every test fails (`bin/dvw-probe: No such file or directory`).

- [ ] **Step 4: Write the probe**

`$AIC/bin/dvw-probe`:

```python
#!/usr/bin/env python3
"""dvw-probe: describe this container from the inside as one JSON document.

Run by the dvw catalog service through `docker exec` (one exec per container)
so it can show tmux windows, running agent CLIs, git state and cgroup usage
without any other Docker API access. Contract: no arguments, one JSON object
on stdout, exit 0 in every case that reaches Python. Each section is null
when it cannot be computed; a section that overran its share of the time
budget is null and sets "partial": true.

Test hooks: DVW_PROBE_PROC, DVW_PROBE_CGROUP, DVW_PROBE_WORKSPACE,
DVW_PROBE_BUDGET (seconds). Spec: dvw docs/superpowers/specs/
2026-09-01-docker-proxy-probe-design.md.
"""
import json
import os
import subprocess
import sys
import time

SCHEMA = 1
AGENT_CLIS = ("claude", "codex", "cursor-agent", "opencode")
WRAPPERS = ("node", "python", "python3", "bun")


class Budget:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds
        self.partial = False

    def remaining(self, cap):
        return max(0.0, min(cap, self.end - time.monotonic()))


def _run(argv, timeout):
    if timeout <= 0:
        raise subprocess.TimeoutExpired(argv, timeout)
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def _int(s, default=None):
    try:
        return int(s)
    except (TypeError, ValueError):
        return default


def collect_tmux(budget):
    per_call = budget.remaining(1.5)
    try:
        r = _run(["tmux", "list-sessions", "-F",
                  "#{session_name}\t#{session_attached}\t#{session_activity}"], per_call)
    except (OSError, subprocess.TimeoutExpired) as e:
        if isinstance(e, subprocess.TimeoutExpired):
            budget.partial = True
        return None
    if r.returncode != 0:
        return None
    sessions = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        sessions.append({"name": parts[0], "attached": _int(parts[1], 0),
                         "activity": _int(parts[2], -1)})
    windows = []
    if any(s["name"] == "work" for s in sessions):
        try:
            r = _run(["tmux", "list-windows", "-t", "work", "-F",
                      "#{window_id}\t#{window_name}\t#{window_active}"
                      "\t#{window_activity}\t#{@waiting}\t#{pane_current_command}"],
                     budget.remaining(1.5))
        except (OSError, subprocess.TimeoutExpired) as e:
            if isinstance(e, subprocess.TimeoutExpired):
                budget.partial = True
            return {"sessions": sessions, "windows": []}
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) != 6 or not parts[0].startswith("@"):
                    continue
                waiting = _int(parts[4])
                windows.append({
                    "id": parts[0], "name": parts[1], "active": parts[2] == "1",
                    "activity": _int(parts[3], -1),
                    "waiting_since": waiting if waiting is not None and waiting >= 0 else None,
                    "command": parts[5],
                })
    return {"sessions": sessions, "windows": windows}


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def collect_agents(proc):
    try:
        btime = None
        for line in _read(os.path.join(proc, "stat")).decode("ascii", "replace").splitlines():
            if line.startswith("btime "):
                btime = _int(line.split()[1])
        hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
        agents = []
        for name in os.listdir(proc):
            if not name.isdigit():
                continue
            pdir = os.path.join(proc, name)
            try:
                comm = _read(os.path.join(pdir, "comm")).decode("utf-8", "replace").strip()
                argv = _read(os.path.join(pdir, "cmdline")).split(b"\0")
            except OSError:
                continue
            argv = [a.decode("utf-8", "replace") for a in argv if a]
            cli = None
            if comm in AGENT_CLIS:
                cli = comm
            elif argv and os.path.basename(argv[0]) in AGENT_CLIS:
                cli = os.path.basename(argv[0])
            elif len(argv) > 1 and os.path.basename(argv[0]) in WRAPPERS \
                    and os.path.basename(argv[1]) in AGENT_CLIS:
                cli = os.path.basename(argv[1])
            if cli is None:
                continue
            started = None
            try:
                stat = _read(os.path.join(pdir, "stat")).decode("ascii", "replace")
                fields = stat[stat.rindex(")") + 2:].split()
                ticks = _int(fields[19])
                if btime is not None and ticks is not None:
                    started = btime + ticks // hz
            except (OSError, ValueError, IndexError):
                pass
            try:
                cwd = os.readlink(os.path.join(pdir, "cwd"))
            except OSError:
                cwd = None
            agents.append({"cli": cli, "pid": int(name), "started": started, "cwd": cwd})
        agents.sort(key=lambda a: a["pid"])
        return agents
    except OSError:
        return None


def _workspace_root():
    env = os.environ.get("DVW_PROBE_WORKSPACE") or os.environ.get("WORKSPACE_FOLDER")
    if env:
        return env if os.path.isdir(env) else None
    try:
        entries = [e for e in os.listdir("/workspaces") if os.path.isdir(os.path.join("/workspaces", e))]
    except OSError:
        return None
    return os.path.join("/workspaces", entries[0]) if len(entries) == 1 else None


def collect_git(budget):
    root = _workspace_root()
    if root is None:
        return None
    out = {"root": root, "branch": None, "head": None, "dirty": None, "ahead": None, "behind": None}

    def g(*args):
        r = _run(["git", "-C", root, *args], budget.remaining(2.0))
        return r.stdout.strip() if r.returncode == 0 else None

    try:
        out["branch"] = g("rev-parse", "--abbrev-ref", "HEAD")
        out["head"] = g("rev-parse", "--short", "HEAD")
        status = g("status", "--porcelain")
        out["dirty"] = bool(status) if status is not None else None
        counts = g("rev-list", "--left-right", "--count", "HEAD...@{upstream}")
        if counts:
            a, b = counts.split()
            out["ahead"], out["behind"] = _int(a), _int(b)
    except subprocess.TimeoutExpired:
        budget.partial = True
        return None
    except OSError:
        return None
    if out["branch"] is None and out["head"] is None:
        return None
    return out


def collect_cgroup(cg):
    try:
        mem_max = _read(os.path.join(cg, "memory.max")).decode().strip()
        cpu_usec = None
        for line in _read(os.path.join(cg, "cpu.stat")).decode().splitlines():
            if line.startswith("usage_usec "):
                cpu_usec = _int(line.split()[1])
        return {
            "mem_current": _int(_read(os.path.join(cg, "memory.current")).decode().strip()),
            "mem_max": None if mem_max == "max" else _int(mem_max),
            "cpu_usec": cpu_usec,
            "nr_procs": _int(_read(os.path.join(cg, "pids.current")).decode().strip()),
        }
    except OSError:
        return None


def main():
    if len(sys.argv) > 1:
        print(json.dumps({"schema": SCHEMA, "error": "dvw-probe takes no arguments"}))
        return 0
    budget = Budget(float(os.environ.get("DVW_PROBE_BUDGET", "3")))
    proc = os.environ.get("DVW_PROBE_PROC", "/proc")
    cg = os.environ.get("DVW_PROBE_CGROUP", "/sys/fs/cgroup")
    doc = {"schema": SCHEMA, "ts": int(time.time()), "partial": False,
           "tmux": None, "agents": None, "git": None, "cgroup": None}
    for key, fn in (("cgroup", lambda: collect_cgroup(cg)),
                    ("agents", lambda: collect_agents(proc)),
                    ("tmux", lambda: collect_tmux(budget)),
                    ("git", lambda: collect_git(budget))):
        try:
            doc[key] = fn()
        except Exception:  # a collector must never take the document down
            doc[key] = None
    doc["partial"] = budget.partial
    sys.stdout.write(json.dumps(doc, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Then `chmod +x $AIC/bin/dvw-probe`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/bats/run.sh dvw-probe`
Expected: 11 tests, all `ok`. If the `started` assertion fails because `SC_CLK_TCK` is not 100 on the dev container, keep the test and set `hz` from `os.sysconf` (it is 100 on Linux; the fixture uses 500 ticks = 5 s).

- [ ] **Step 6: Commit**

```bash
git add bin/dvw-probe tests/bats/dvw-probe.bats
git commit -m "$(cat <<'EOF'
feat: dvw-probe, one exec that describes the container from inside

tmux sessions and work windows, running agent CLIs, git state of the
workspace checkout and cgroup usage, as one JSON document. Replaces the
three tmux execs the dvw catalog makes today so its docker proxy can
allow exactly one command. Spec lives in dvw:
docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 2: Provision `dvw-probe` into `~/.local/bin`

**Files:**
- Modify: `$AIC/lib/provision-integrations.sh` (after line 71, the end of `install_agent_notify_symlink`)
- Modify: `$AIC/install.sh:123` (call list)
- Modify: `$AIC/tests/bats/install.bats` (after line 190)

**Interfaces:**
- Produces: `install_dvw_probe_symlink()`; `~/.local/bin/dvw-probe -> $SCRIPT_DIR/bin/dvw-probe` in every container after install or boot sync (install.sh is what boot sync re-runs in reconcile mode).

- [ ] **Step 1: Write the failing test**

Append to `$AIC/tests/bats/install.bats` after the agent-notify symlink test:

```bash
@test "install.sh symlinks dvw-probe into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/dvw-probe" ]
  [ -x "$HOME/.local/bin/dvw-probe" ]
  readlink "$HOME/.local/bin/dvw-probe" | grep -q "bin/dvw-probe"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/bats/run.sh install -f 'dvw-probe'`
Expected: 1 test, `not ok` on the `-L` assertion.

- [ ] **Step 3: Add the provisioning function and the call**

In `$AIC/lib/provision-integrations.sh`, insert after `install_agent_notify_symlink()`:

```bash
# --- dvw-probe CLI symlink ---
# One exec, one JSON document: the dvw catalog service runs `dvw-probe`
# inside each workspace container through its docker proxy, which allows
# exactly that command. Lives here (not in the image) so a running
# container gets it on the next boot sync without a rebuild.
install_dvw_probe_symlink() {
  header "dvw-probe CLI"
  local src="$SCRIPT_DIR/bin/dvw-probe" dest="$HOME/.local/bin/dvw-probe"
  [[ -f "$src" ]] || { warn "bin/dvw-probe not found, skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"; ln -sf "$src" "$dest"
  ok "dvw-probe installed at $dest -> $src"
}
```

In `$AIC/install.sh`, after the line `  install_agent_notify_symlink`, add `  install_dvw_probe_symlink`.

- [ ] **Step 4: Run the install tests**

Run: `tests/bats/run.sh install`
Expected: all `ok`, including the new one.

- [ ] **Step 5: Run the whole aicoding suite**

Run: `tests/bats/run.sh`
Expected: all `ok` (count is whatever `main` has plus 12).

- [ ] **Step 6: Commit and push**

```bash
git add lib/provision-integrations.sh install.sh tests/bats/install.bats
git commit -m "$(cat <<'EOF'
feat: provision dvw-probe into ~/.local/bin on install and boot sync

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
git push -u origin feat/dvw-probe
```

---

## Group B: dvw

All paths below are relative to `$DVW`.

### Task 3: Proxy core: request parsing, route table, deny path

**Files:**
- Create: `catalog-service/proxy/__init__.py` (empty)
- Create: `catalog-service/proxy/dvw_docker_proxy.py`
- Create: `catalog-service/tests/test_proxy.py`

**Interfaces:**
- Produces (module `proxy.dvw_docker_proxy`):
  - `class Request: method: str, target: str, path: str, query: str, headers: list[tuple[str,str]], body: bytes, head: bytes` where `path` has the `/v1.NN` prefix stripped and `head` is the raw request head as received.
  - `class BadRequest(Exception)`, `class Forbidden(Exception)`.
  - `read_request(sock) -> Request` (raises `BadRequest`).
  - `class Route: kind: str, container_id: str | None, exec_id: str | None` with `kind` in `{"plain", "exec_create", "exec_start", "exec_inspect"}`.
  - `route(req: Request) -> Route` (raises `Forbidden`).
  - `class ExecRegistry: add(exec_id: str) -> None; check(exec_id: str) -> bool` (60 s TTL, capacity 256).
  - `validate_exec_body(body: bytes) -> tuple[bytes, str]` returns `(normalized_body, cmd_label)` (Task 4).
  - `serve(listen_sock: socket.socket, upstream: str, registry: ExecRegistry, stop: threading.Event) -> None`.
  - `connect_upstream(upstream: str) -> socket.socket` where `upstream` is `unix:/path` or `tcp://host:port`.
  - `main() -> int`.
  - Constants: `MAX_HEAD = 16 * 1024`, `MAX_BODY = 64 * 1024`, `MAX_RELAY = 1024 * 1024`, `DENY_BODY = b'{"message":"dvw-docker-proxy: route not allowed"}'`.

- [ ] **Step 1: Write the failing tests**

`catalog-service/tests/test_proxy.py`:

```python
"""dvw-docker-proxy: allowlisting proxy in front of docker.sock.

The proxy runs in a thread on a temp unix socket; upstream is a scripted fake
on another temp unix socket. Tests speak raw HTTP so what reaches the wire is
exactly what is asserted.
"""

from __future__ import annotations

import json
import os
import socket
import threading

import pytest

from proxy import dvw_docker_proxy as px


class FakeUpstream:
    """Reads one HTTP request per connection, records it, answers from a
    handler. handler(method, path, headers, body, conn) -> bytes | None; when
    it returns None it has written to conn itself (upgrade scenarios)."""

    def __init__(self, path, handler):
        self.path = path
        self.handler = handler
        self.requests: list[tuple[str, str, dict, bytes]] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            threading.Thread(target=self._one, args=(conn,), daemon=True).start()

    def _one(self, conn):
        try:
            req = px.read_request(conn)
        except px.BadRequest:
            conn.close()
            return
        headers = {k.lower(): v for k, v in req.headers}
        self.requests.append((req.method, req.target, headers, req.body))
        resp = self.handler(req.method, req.target, headers, req.body, conn)
        if resp is not None:
            conn.sendall(resp)
            conn.close()

    def close(self):
        self.stop.set()
        self.thread.join(1)
        self.sock.close()


def http(status, body=b"", extra=b""):
    return (f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n").encode() + extra + b"\r\n" + body


def ok_json(obj):
    return http("200 OK", json.dumps(obj).encode())


@pytest.fixture
def stack(tmp_path):
    """Yields (send, upstream) where send(raw_request_bytes) -> raw response."""
    up_path = str(tmp_path / "up.sock")
    px_path = str(tmp_path / "px.sock")
    state = {"handler": lambda m, p, h, b, c: ok_json({"echo": p})}
    upstream = FakeUpstream(up_path, lambda *a: state["handler"](*a))
    listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listen.bind(px_path)
    listen.listen(8)
    stop = threading.Event()
    registry = px.ExecRegistry()
    t = threading.Thread(
        target=px.serve, args=(listen, f"unix:{up_path}", registry, stop), daemon=True)
    t.start()

    def send(raw: bytes, read_all=True) -> bytes:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(3)
        c.connect(px_path)
        c.sendall(raw)
        chunks = []
        while True:
            try:
                d = c.recv(65536)
            except socket.timeout:
                break
            if not d:
                break
            chunks.append(d)
        c.close()
        return b"".join(chunks)

    class Stack:
        pass

    s = Stack()
    s.send = send
    s.upstream = upstream
    s.registry = registry
    s.set_handler = lambda h: state.__setitem__("handler", h)
    yield s
    stop.set()
    listen.close()
    upstream.close()


def req(method, target, body=b"", headers=""):
    return (f"{method} {target} HTTP/1.1\r\nHost: docker\r\n{headers}"
            f"Content-Length: {len(body)}\r\n\r\n").encode() + body


def status_of(resp: bytes) -> int:
    return int(resp.split(b" ", 2)[1])


def body_of(resp: bytes) -> bytes:
    return resp.split(b"\r\n\r\n", 1)[1]


# ---- allowed plain routes --------------------------------------------------

@pytest.mark.parametrize("target", [
    "/_ping", "/version", "/info",
    "/containers/json?all=1&limit=-1&filters=%7B%22label%22%3A%5B%22x%22%5D%7D",
    "/containers/abc123/json",
    "/containers/abc123/stats?stream=false",
    "/containers/abc123/stats?stream=0",
    "/containers/abc123/stats?stream=False",
])
def test_allowed_get_routes_reach_upstream_with_query(stack, target):
    resp = stack.send(req("GET", target))
    assert status_of(resp) == 200
    assert json.loads(body_of(resp)) == {"echo": target}
    assert stack.upstream.requests[-1][1] == target


def test_version_prefix_is_stripped_for_routing_but_forwarded(stack):
    resp = stack.send(req("GET", "/v1.45/_ping"))
    assert status_of(resp) == 200
    assert stack.upstream.requests[-1][1] == "/v1.45/_ping"


def test_response_gets_connection_close(stack):
    resp = stack.send(req("GET", "/_ping"))
    assert b"\r\nConnection: close\r\n" in resp.split(b"\r\n\r\n", 1)[0]


# ---- denied ----------------------------------------------------------------

@pytest.mark.parametrize("method,target", [
    ("POST", "/containers/create"),
    ("POST", "/containers/abc123/start"),
    ("DELETE", "/containers/abc123"),
    ("GET", "/images/json"),
    ("GET", "/volumes"),
    ("GET", "/networks"),
    ("POST", "/build"),
    ("POST", "/commit"),
    ("GET", "/swarm"),
    ("GET", "/system/df"),
    ("GET", "/events"),
    ("HEAD", "/_ping"),
    ("PUT", "/containers/abc123/archive?path=/"),
    ("GET", "/containers/abc123/stats"),
    ("GET", "/containers/abc123/stats?stream=true"),
    ("GET", "/containers/abc123/logs?stdout=1"),
    ("GET", "/containers/abc123/top"),
    ("GET", "/containers/../json"),
    ("GET", "/containers/abc%2Fjson"),
    ("POST", "/exec/deadbeef/start"),
    ("GET", "/exec/deadbeef/json"),
])
def test_denied_routes_never_reach_upstream(stack, method, target):
    before = len(stack.upstream.requests)
    resp = stack.send(req(method, target, body=b"{}"))
    assert status_of(resp) == 403
    assert body_of(resp) == px.DENY_BODY
    assert len(stack.upstream.requests) == before


def test_malformed_request_line_is_400(stack):
    resp = stack.send(b"GARBAGE\r\n\r\n")
    assert status_of(resp) == 400


def test_oversized_head_is_400(stack):
    resp = stack.send(b"GET /_ping HTTP/1.1\r\nX: " + b"a" * (px.MAX_HEAD + 10) + b"\r\n\r\n")
    assert status_of(resp) == 400


def test_chunked_request_body_is_400(stack):
    resp = stack.send(b"POST /containers/abc/exec HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    assert status_of(resp) == 400
```

- [ ] **Step 2: Run to verify failure**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py`
Expected: `ModuleNotFoundError: No module named 'proxy'`.

- [ ] **Step 3: Write the proxy core**

`catalog-service/proxy/__init__.py`: empty file.

`catalog-service/proxy/dvw_docker_proxy.py`:

```python
#!/usr/bin/python3
"""dvw-docker-proxy: the only path from the dvw catalog service to Docker.

Listens on a unix socket that systemd creates with mode 0600 for the catalog
user, talks to /var/run/docker.sock as a member of the docker group, and
forwards exactly the routes the catalog needs. Everything else is refused
before the upstream is contacted. Exec is restricted to one command
(`dvw-probe`, plus a transitional tmux form), so a compromised catalog can
read tmux state and nothing more. Stdlib only; runs with /usr/bin/python3.

Spec: docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md.
"""
from __future__ import annotations

import json
import logging
import os
import re
import selectors
import socket
import sys
import threading
import time

log = logging.getLogger("dvw-docker-proxy")

MAX_HEAD = 16 * 1024
MAX_BODY = 64 * 1024
MAX_RELAY = 1024 * 1024
EXEC_TTL = 60.0
EXEC_CAP = 256
DENY_BODY = b'{"message":"dvw-docker-proxy: route not allowed"}'
BAD_BODY = b'{"message":"dvw-docker-proxy: malformed request"}'

_ID = r"[A-Za-z0-9_.-]{1,128}"
_VERSION_PREFIX = re.compile(r"^/v\d+\.\d+(?=/)")
_ROUTES = [
    ("GET", re.compile(r"^/_ping$"), "plain"),
    ("GET", re.compile(r"^/version$"), "plain"),
    ("GET", re.compile(r"^/info$"), "plain"),
    ("GET", re.compile(r"^/containers/json$"), "plain"),
    ("GET", re.compile(rf"^/containers/(?P<cid>{_ID})/json$"), "plain"),
    ("GET", re.compile(rf"^/containers/(?P<cid>{_ID})/stats$"), "stats"),
    ("POST", re.compile(rf"^/containers/(?P<cid>{_ID})/exec$"), "exec_create"),
    ("POST", re.compile(rf"^/exec/(?P<eid>{_ID})/start$"), "exec_start"),
    ("GET", re.compile(rf"^/exec/(?P<eid>{_ID})/json$"), "exec_inspect"),
]
_STREAM_OFF = {"false", "0", "False"}


class BadRequest(Exception):
    pass


class Forbidden(Exception):
    pass


class Request:
    __slots__ = ("method", "target", "path", "query", "headers", "body", "head")

    def __init__(self, method, target, headers, body, head):
        self.method = method
        self.target = target
        path, _, query = target.partition("?")
        self.path = _VERSION_PREFIX.sub("", path)
        self.query = query
        self.headers = headers
        self.body = body
        self.head = head


class Route:
    __slots__ = ("kind", "container_id", "exec_id")

    def __init__(self, kind, container_id=None, exec_id=None):
        self.kind = kind
        self.container_id = container_id
        self.exec_id = exec_id


def _recv_until(sock, marker, limit):
    buf = b""
    while marker not in buf:
        if len(buf) > limit:
            raise BadRequest("head too large")
        chunk = sock.recv(4096)
        if not chunk:
            if not buf:
                raise BadRequest("empty")
            raise BadRequest("truncated head")
        buf += chunk
    head, rest = buf.split(marker, 1)
    return head + marker, rest


def _recv_exact(sock, n, initial):
    buf = initial
    while len(buf) < n:
        chunk = sock.recv(min(65536, n - len(buf)))
        if not chunk:
            raise BadRequest("truncated body")
        buf += chunk
    return buf[:n], buf[n:]


def read_request(sock) -> Request:
    head, rest = _recv_until(sock, b"\r\n\r\n", MAX_HEAD)
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1.") or not parts[1].startswith("/"):
        raise BadRequest("bad request line")
    method, target = parts[0], parts[1]
    headers = []
    length = 0
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition(":")
        if not sep:
            raise BadRequest("bad header")
        name, value = name.strip(), value.strip()
        headers.append((name, value))
        lname = name.lower()
        if lname == "transfer-encoding":
            raise BadRequest("chunked request bodies are not accepted")
        if lname == "content-length":
            try:
                length = int(value)
            except ValueError:
                raise BadRequest("bad content-length") from None
            if length < 0 or length > MAX_BODY:
                raise BadRequest("body too large")
    body, _ = _recv_exact(sock, length, rest)
    return Request(method, target, headers, body, head)


def route(req: Request) -> Route:
    for method, pattern, kind in _ROUTES:
        if req.method != method:
            continue
        m = pattern.match(req.path)
        if not m:
            continue
        cid = m.groupdict().get("cid")
        eid = m.groupdict().get("eid")
        if kind == "stats":
            params = dict(p.partition("=")[::2] for p in req.query.split("&") if p)
            if params.get("stream") not in _STREAM_OFF:
                raise Forbidden("stats without stream=false")
            return Route("plain", container_id=cid)
        return Route(kind, container_id=cid, exec_id=eid)
    raise Forbidden(f"{req.method} {req.path}")


class ExecRegistry:
    def __init__(self, ttl=EXEC_TTL, cap=EXEC_CAP):
        self._ttl = ttl
        self._cap = cap
        self._ids: dict[str, float] = {}
        self._lock = threading.Lock()

    def add(self, exec_id: str) -> None:
        now = time.monotonic()
        with self._lock:
            for k in [k for k, t in self._ids.items() if now - t > self._ttl]:
                del self._ids[k]
            while len(self._ids) >= self._cap:
                del self._ids[next(iter(self._ids))]
            self._ids[exec_id] = now

    def check(self, exec_id: str) -> bool:
        now = time.monotonic()
        with self._lock:
            t = self._ids.get(exec_id)
            return t is not None and now - t <= self._ttl


def validate_exec_body(body: bytes) -> tuple[bytes, str]:
    raise Forbidden("exec not implemented yet")  # replaced in Task 4


def connect_upstream(upstream: str) -> socket.socket:
    if upstream.startswith("unix:"):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(upstream[len("unix:"):].replace("//", "/", 1) if upstream.startswith("unix://") else upstream[len("unix:"):])
        return s
    if upstream.startswith("tcp://"):
        host, _, port = upstream[len("tcp://"):].partition(":")
        return socket.create_connection((host, int(port)), timeout=10)
    raise ValueError(f"unsupported upstream {upstream!r}")


def _send_response(sock, status: str, body: bytes) -> None:
    head = (f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
    try:
        sock.sendall(head + body)
    except OSError:
        pass


def _rebuild_head(req: Request, body: bytes) -> bytes:
    """Request head for the upstream: same target, hop-by-hop headers dropped,
    Content-Length rewritten for the (possibly normalized) body."""
    out = [f"{req.method} {req.target} HTTP/1.1"]
    for name, value in req.headers:
        if name.lower() in ("content-length", "connection", "transfer-encoding"):
            continue
        out.append(f"{name}: {value}")
    out.append(f"Content-Length: {len(body)}")
    out.append("Connection: close")
    return ("\r\n".join(out) + "\r\n\r\n").encode("latin-1")


def _read_response_head(up) -> tuple[bytes, bytes]:
    head, rest = _recv_until(up, b"\r\n\r\n", MAX_HEAD)
    return head, rest


def _with_connection_close(head: bytes) -> bytes:
    lines = [l for l in head.decode("latin-1").split("\r\n")
             if l and not l.lower().startswith("connection:")]
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def _relay_plain(client, up, req: Request, body: bytes) -> None:
    up.sendall(_rebuild_head(req, body) + body)
    head, rest = _read_response_head(up)
    client.sendall(_with_connection_close(head) + rest)
    while True:
        chunk = up.recv(65536)
        if not chunk:
            break
        client.sendall(chunk)


def _relay_exec_start(client, up, req: Request, body: bytes) -> tuple[bytes, bytes]:
    raise Forbidden("exec start not implemented yet")  # replaced in Task 5


def handle_connection(client, upstream: str, registry: ExecRegistry) -> None:
    try:
        client.settimeout(30)
        try:
            req = read_request(client)
        except BadRequest as e:
            log.info("verdict=bad reason=%s", e)
            _send_response(client, "400 Bad Request", BAD_BODY)
            return
        label = ""
        try:
            r = route(req)
            body = req.body
            if r.kind == "exec_create":
                body, label = validate_exec_body(req.body)
            elif r.kind in ("exec_start", "exec_inspect"):
                if not registry.check(r.exec_id):
                    raise Forbidden("unknown exec id")
                if r.kind == "exec_start":
                    try:
                        opts = json.loads(body or b"{}")
                    except ValueError:
                        raise Forbidden("exec start body is not JSON") from None
                    if not isinstance(opts, dict) or opts.get("Detach") not in (None, False):
                        raise Forbidden("exec start must not detach")
        except Forbidden as e:
            log.info("verdict=deny method=%s path=%s reason=%s",
                     req.method, req.target[:200], e)
            _send_response(client, "403 Forbidden", DENY_BODY)
            return
        log.info("verdict=allow method=%s path=%s%s", req.method, req.path,
                 f" cmd={label}" if label else "")
        up = connect_upstream(upstream)
        try:
            up.settimeout(30)
            if r.kind == "exec_start":
                _relay_exec_start(client, up, req, body)
            elif r.kind == "exec_create":
                up.sendall(_rebuild_head(req, body) + body)
                head, rest = _read_response_head(up)
                payload = rest
                while True:
                    chunk = up.recv(65536)
                    if not chunk:
                        break
                    payload += chunk
                status = head.split(b" ", 2)[1]
                if status == b"201":
                    try:
                        exec_id = json.loads(_strip_chunked(head, payload)).get("Id")
                    except ValueError:
                        exec_id = None
                    if isinstance(exec_id, str):
                        registry.add(exec_id)
                client.sendall(_with_connection_close(head) + payload)
            else:
                _relay_plain(client, up, req, body)
        finally:
            up.close()
    except OSError as e:
        log.debug("connection error: %s", e)
    finally:
        try:
            client.close()
        except OSError:
            pass


def _strip_chunked(head: bytes, payload: bytes) -> bytes:
    """Docker answers exec create with Content-Length, but tolerate chunked."""
    if b"transfer-encoding: chunked" not in head.lower():
        return payload
    out = b""
    rest = payload
    while rest:
        size_line, _, rest = rest.partition(b"\r\n")
        size = int(size_line.split(b";")[0], 16)
        if size == 0:
            break
        out += rest[:size]
        rest = rest[size + 2:]
    return out


def serve(listen_sock, upstream: str, registry: ExecRegistry, stop: threading.Event) -> None:
    listen_sock.settimeout(0.5)
    while not stop.is_set():
        try:
            client, _ = listen_sock.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=handle_connection, args=(client, upstream, registry),
                         daemon=True).start()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    upstream = os.environ.get("DVW_PROXY_UPSTREAM", "unix:/var/run/docker.sock")
    if os.environ.get("LISTEN_FDS") == "1" and os.environ.get("LISTEN_PID") in (None, str(os.getpid())):
        listen = socket.socket(fileno=3)
    else:
        path = os.environ.get("DVW_PROXY_LISTEN")
        if not path:
            print("dvw-docker-proxy: no LISTEN_FDS and no DVW_PROXY_LISTEN", file=sys.stderr)
            return 2
        if os.path.exists(path):
            os.unlink(path)
        listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listen.bind(path)
        os.chmod(path, 0o600)
        listen.listen(64)
    log.info("dvw-docker-proxy listening, upstream=%s", upstream)
    serve(listen, upstream, ExecRegistry(), threading.Event())
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Note on `connect_upstream`: accept both `unix:/path` and `unix:///path`; the one-liner above handles both. Keep it readable if you prefer two lines.

- [ ] **Step 4: Run the tests**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py`
Expected: all pass. The denied `POST /exec/deadbeef/start` and `GET /exec/deadbeef/json` cases pass because the registry does not know the id.

- [ ] **Step 5: Commit**

```bash
git add catalog-service/proxy catalog-service/tests/test_proxy.py
git commit -m "$(cat <<'EOF'
feat(proxy): dvw-docker-proxy core, exact route table with deny-by-default

Stdlib unix-socket proxy for the catalog service. Nine allowed routes,
everything else 403 before the upstream is contacted. Exec validation and
the upgraded-stream relay follow in the next commits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 4: Exec create validation and exec-id registry

**Files:**
- Modify: `catalog-service/proxy/dvw_docker_proxy.py` (`validate_exec_body`)
- Modify: `catalog-service/tests/test_proxy.py` (append)

**Interfaces:**
- Produces: `validate_exec_body(body) -> (normalized_json_bytes, label)` where `label` is `"dvw-probe"` or `"tmux list-sessions"` / `"tmux list-windows"`. Raises `Forbidden`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_proxy.py`:

```python
# ---- exec create -----------------------------------------------------------

DOCKER_PY_EXEC = {
    "Container": "abc123", "User": "", "Privileged": False, "Tty": False,
    "AttachStdin": False, "AttachStdout": True, "AttachStderr": True,
    "Cmd": ["dvw-probe"], "Env": None,
}


def exec_create(stack, body: dict, cid="abc123"):
    return stack.send(req("POST", f"/containers/{cid}/exec",
                          json.dumps(body).encode(),
                          "Content-Type: application/json\r\n"))


def test_exec_probe_is_forwarded_normalized_and_id_registered(stack):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e1"}'))
    resp = exec_create(stack, DOCKER_PY_EXEC)
    assert status_of(resp) == 201
    assert json.loads(body_of(resp)) == {"Id": "e1"}
    m, p, h, b = stack.upstream.requests[-1]
    assert p == "/containers/abc123/exec"
    sent = json.loads(b)
    assert sent["Cmd"] == ["dvw-probe"]
    assert sent["AttachStdout"] is True and sent["AttachStderr"] is True
    assert h["content-length"] == str(len(b))
    assert stack.registry.check("e1")


def test_exec_transitional_tmux_forms_allowed(stack):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e2"}'))
    for cmd in (["tmux", "list-sessions", "-F", "#{session_name} #{session_activity}"],
                ["tmux", "list-windows", "-t", "work", "-F", "x"]):
        resp = exec_create(stack, {**DOCKER_PY_EXEC, "Cmd": cmd})
        assert status_of(resp) == 201, cmd


@pytest.mark.parametrize("patch", [
    {"Cmd": ["sh"]},
    {"Cmd": ["sh", "-c", "dvw-probe"]},
    {"Cmd": ["dvw-probe", "--x"]},
    {"Cmd": ["/usr/local/bin/dvw-probe"]},
    {"Cmd": "dvw-probe"},
    {"Cmd": []},
    {"Cmd": ["tmux", "kill-server"]},
    {"Cmd": ["tmux"]},
    {"Privileged": True},
    {"Tty": True},
    {"AttachStdin": True},
    {"User": "root"},
    {"User": "0"},
    {"Env": ["LD_PRELOAD=/tmp/x.so"]},
    {"WorkingDir": "/"},
    {"DetachKeys": "ctrl-p"},
])
def test_exec_variants_are_denied_before_upstream(stack, patch):
    before = len(stack.upstream.requests)
    resp = exec_create(stack, {**DOCKER_PY_EXEC, **patch})
    assert status_of(resp) == 403, patch
    assert len(stack.upstream.requests) == before


def test_exec_duplicate_keys_use_last_and_are_normalized(stack):
    # JSON with two Cmd keys: Python keeps the last one, which is the one
    # validated and the only one re-serialized.
    raw = b'{"Cmd":["sh"],"AttachStdout":true,"Cmd":["dvw-probe"]}'
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e3"}'))
    resp = stack.send(req("POST", "/containers/abc123/exec", raw))
    assert status_of(resp) == 201
    assert json.loads(stack.upstream.requests[-1][3])["Cmd"] == ["dvw-probe"]
    assert stack.upstream.requests[-1][3].count(b'"Cmd"') == 1


def test_exec_non_json_body_is_denied(stack):
    resp = stack.send(req("POST", "/containers/abc123/exec", b"not json"))
    assert status_of(resp) == 403


def test_exec_registry_ttl_and_cap():
    reg = px.ExecRegistry(ttl=0.05, cap=2)
    reg.add("a")
    assert reg.check("a")
    reg.add("b")
    reg.add("c")
    assert not reg.check("a") and reg.check("b") and reg.check("c")
    import time
    time.sleep(0.08)
    assert not reg.check("c")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py -k exec`
Expected: the allow tests fail with 403 (stub raises Forbidden); registry test passes already.

- [ ] **Step 3: Implement `validate_exec_body`**

Replace the stub in `dvw_docker_proxy.py`:

```python
_FALSEY = (None, False)
_EMPTY = (None, "", [], {})
_TMUX_SUBCOMMANDS = ("list-sessions", "list-windows")
_PASSTHROUGH = ("Container", "AttachStdout", "AttachStderr", "Tty", "Privileged",
                "AttachStdin", "User", "Env", "WorkingDir", "DetachKeys", "Cmd")


def validate_exec_body(body: bytes) -> tuple[bytes, str]:
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Forbidden("exec body is not JSON") from None
    if not isinstance(data, dict):
        raise Forbidden("exec body is not an object")
    cmd = data.get("Cmd")
    if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
        raise Forbidden("Cmd must be a non-empty list of strings")
    if cmd == ["dvw-probe"]:
        label = "dvw-probe"
    elif cmd[0] == "tmux" and len(cmd) >= 2 and cmd[1] in _TMUX_SUBCOMMANDS:
        label = f"tmux {cmd[1]}"  # transitional, removed with the catalog fallback
    else:
        raise Forbidden(f"Cmd not allowed: {cmd[0]!r}")
    for key in ("Privileged", "Tty", "AttachStdin"):
        if data.get(key) not in _FALSEY:
            raise Forbidden(f"{key} must be absent or false")
    for key in ("User", "Env", "WorkingDir", "DetachKeys"):
        if data.get(key) not in _EMPTY:
            raise Forbidden(f"{key} must be absent or empty")
    clean = {k: data[k] for k in _PASSTHROUGH if k in data}
    return json.dumps(clean, separators=(",", ":")).encode("utf-8"), label
```

- [ ] **Step 4: Run the proxy tests**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add catalog-service/proxy/dvw_docker_proxy.py catalog-service/tests/test_proxy.py
git commit -m "$(cat <<'EOF'
feat(proxy): exec create allows only dvw-probe (and transitional tmux reads)

The body is re-serialized from validated fields, so smuggled keys cannot
reach dockerd. Issued exec ids are remembered for 60 s so start/inspect
can be tied to a create this proxy approved.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 5: Exec start relay over the upgraded stream

**Files:**
- Modify: `catalog-service/proxy/dvw_docker_proxy.py` (`_relay_exec_start`)
- Modify: `catalog-service/tests/test_proxy.py` (append)

**Interfaces:**
- Produces: `_relay_exec_start(client, up, req, body)`: sends the request, forwards the upstream head; if status is 101 relays bytes both ways until either side closes or `MAX_RELAY` bytes have been sent to the client; otherwise behaves like `_relay_plain`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_proxy.py`:

```python
# ---- exec start / inspect ----------------------------------------------------

def _register(stack, exec_id):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", json.dumps({"Id": exec_id}).encode()))
    exec_create(stack, DOCKER_PY_EXEC)


def upgrade_handler(frames: list[bytes], expect_from_client: bytes | None = None):
    def h(m, p, hd, b, conn):
        conn.sendall(b"HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\n"
                     b"Content-Type: application/vnd.docker.raw-stream\r\nUpgrade: tcp\r\n\r\n")
        for f in frames:
            conn.sendall(f)
        conn.close()
        return None
    return h


def test_exec_start_relays_upgraded_stream(stack):
    _register(stack, "e9")
    # docker multiplexed frame: stream 1 (stdout), 4-byte big-endian length
    frame = b"\x01\x00\x00\x00" + (12).to_bytes(4, "big") + b'{"schema":1}'
    stack.set_handler(upgrade_handler([frame]))
    resp = stack.send(req("POST", "/exec/e9/start", b'{"Detach":false,"Tty":false}',
                          "Connection: Upgrade\r\nUpgrade: tcp\r\n"))
    head, rest = resp.split(b"\r\n\r\n", 1)
    assert head.startswith(b"HTTP/1.1 101")
    assert rest == frame
    assert stack.upstream.requests[-1][1] == "/exec/e9/start"
    assert stack.upstream.requests[-1][2].get("upgrade") == "tcp"


def test_exec_start_caps_relayed_bytes(stack):
    _register(stack, "e10")
    big = b"\x01\x00\x00\x00" + (2 * px.MAX_RELAY).to_bytes(4, "big") + b"x" * (2 * px.MAX_RELAY)
    stack.set_handler(upgrade_handler([big]))
    resp = stack.send(req("POST", "/exec/e10/start", b"{}"))
    _, rest = resp.split(b"\r\n\r\n", 1)
    assert len(rest) <= px.MAX_RELAY


def test_exec_start_detach_true_denied(stack):
    _register(stack, "e11")
    resp = stack.send(req("POST", "/exec/e11/start", b'{"Detach":true}'))
    assert status_of(resp) == 403


def test_exec_start_plain_error_response_is_forwarded(stack):
    _register(stack, "e12")
    stack.set_handler(lambda m, p, h, b, c: http("409 Conflict", b'{"message":"not running"}'))
    resp = stack.send(req("POST", "/exec/e12/start", b"{}"))
    assert status_of(resp) == 409
    assert b"not running" in body_of(resp)


def test_exec_inspect_for_registered_id(stack):
    _register(stack, "e13")
    stack.set_handler(lambda m, p, h, b, c: ok_json({"ExitCode": 0, "Running": False}))
    resp = stack.send(req("GET", "/exec/e13/json"))
    assert status_of(resp) == 200
    assert json.loads(body_of(resp))["ExitCode"] == 0


def test_exec_id_from_one_container_cannot_be_started_after_ttl(stack):
    stack.registry._ttl = 0.01
    _register(stack, "e14")
    import time
    time.sleep(0.03)
    resp = stack.send(req("POST", "/exec/e14/start", b"{}"))
    assert status_of(resp) == 403
```

- [ ] **Step 2: Run to verify failure**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py -k "exec_start or exec_inspect or ttl"`
Expected: the relay tests fail with 403 from the stub.

- [ ] **Step 3: Implement the relay**

Replace the `_relay_exec_start` stub:

```python
def _relay_exec_start(client, up, req: Request, body: bytes) -> None:
    head_out = [f"{req.method} {req.target} HTTP/1.1"]
    for name, value in req.headers:
        if name.lower() in ("content-length", "transfer-encoding"):
            continue
        head_out.append(f"{name}: {value}")
    head_out.append(f"Content-Length: {len(body)}")
    up.sendall(("\r\n".join(head_out) + "\r\n\r\n").encode("latin-1") + body)
    head, rest = _read_response_head(up)
    status = head.split(b" ", 2)[1]
    if status != b"101":
        client.sendall(_with_connection_close(head) + rest)
        while True:
            chunk = up.recv(65536)
            if not chunk:
                break
            client.sendall(chunk)
        return
    client.sendall(head)
    sent = 0
    if rest:
        client.sendall(rest[:MAX_RELAY])
        sent += len(rest[:MAX_RELAY])
        if sent >= MAX_RELAY:
            return
    # Nothing goes upstream from the client: the exec is never attached to
    # stdin, so half-close our write side towards it and only drain.
    try:
        client.shutdown(socket.SHUT_RD)
    except OSError:
        pass
    up.settimeout(None)
    client.settimeout(None)
    sel = selectors.DefaultSelector()
    sel.register(up, selectors.EVENT_READ)
    try:
        while sent < MAX_RELAY:
            events = sel.select(timeout=30)
            if not events:
                break
            chunk = up.recv(65536)
            if not chunk:
                break
            chunk = chunk[:MAX_RELAY - sent]
            client.sendall(chunk)
            sent += len(chunk)
    finally:
        sel.close()
```

The spec asks for a bidirectional relay; because `AttachStdin` is refused at create time, the only meaningful direction is upstream to client, and reading from the client after the head would only ever see EOF. `SHUT_RD` makes that explicit. Keep the `selectors` loop so a stalled upstream cannot hold the thread forever.

- [ ] **Step 4: Run the proxy tests**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_proxy.py`
Expected: all pass.

- [ ] **Step 5: Run it once by hand against the real local docker (sanity, not a test)**

```bash
cd catalog-service
DVW_PROXY_LISTEN=/tmp/px-manual.sock DVW_PROXY_UPSTREAM=unix:/var/run/docker.sock \
  /usr/bin/python3 proxy/dvw_docker_proxy.py & PXPID=$!
sleep 0.5
curl -s --unix-socket /tmp/px-manual.sock http://d/_ping; echo
curl -s -o /dev/null -w '%{http_code}\n' --unix-socket /tmp/px-manual.sock http://d/images/json
curl -s -o /dev/null -w '%{http_code}\n' --unix-socket /tmp/px-manual.sock -X POST \
  -H 'Content-Type: application/json' -d '{"Image":"alpine","HostConfig":{"Binds":["/:/host"]}}' \
  http://d/containers/create
kill $PXPID; rm -f /tmp/px-manual.sock
```
Expected: `OK`, `403`, `403`.

- [ ] **Step 6: Commit**

```bash
git add catalog-service/proxy/dvw_docker_proxy.py catalog-service/tests/test_proxy.py
git commit -m "$(cat <<'EOF'
feat(proxy): relay the exec start stream, capped at 1 MiB per exec

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 6: `app/probe.py`: `ProbeReport` and `run_probe`

**Files:**
- Create: `catalog-service/app/probe.py`
- Create: `catalog-service/tests/test_probe.py`

**Interfaces:**
- Produces:
  - `class ProbeSession(BaseModel)`: `name: str`, `attached: int = 0`, `activity: int = -1`.
  - `class ProbeWindow(BaseModel)`: `id: str`, `name: str`, `active: bool = False`, `activity: int = -1`, `waiting_since: int | None = None`, `command: str = ""`.
  - `class ProbeTmux(BaseModel)`: `sessions: list[ProbeSession]`, `windows: list[ProbeWindow]`.
  - `class ProbeAgent(BaseModel)`: `cli: str`, `pid: int`, `started: int | None`, `cwd: str | None`.
  - `class ProbeGit(BaseModel)`: `root: str | None`, `branch: str | None`, `head: str | None`, `dirty: bool | None`, `ahead: int | None`, `behind: int | None`.
  - `class ProbeCgroup(BaseModel)`: `mem_current: int | None`, `mem_max: int | None`, `cpu_usec: int | None`, `nr_procs: int | None`.
  - `class ProbeReport(BaseModel)` with `extra="ignore"`: `schema_: int = Field(alias="schema")`, `ts: int`, `partial: bool = False`, `tmux: ProbeTmux | None`, `agents: list[ProbeAgent] | None`, `git: ProbeGit | None`, `cgroup: ProbeCgroup | None`. Helper methods `work_activity() -> int`, `work_attached() -> int`, `work_windows() -> list[WindowInfo]`.
  - `class ProbeMissing(Exception)`, `class ProbeError(Exception)`.
  - `run_probe(container) -> ProbeReport | None` (raises `ProbeMissing` on exit 126/127; returns `None` on any other failure).
  - `MAX_OUTPUT = 256 * 1024`.

- [ ] **Step 1: Write the failing tests**

`catalog-service/tests/test_probe.py`:

```python
"""ProbeReport parsing and run_probe: the probe's output is untrusted input."""

from __future__ import annotations

import json

import pytest

from app.probe import MAX_OUTPUT, ProbeMissing, ProbeReport, run_probe
from tests.test_resolver import FakeExecResult

GOOD = {
    "schema": 1, "ts": 1756800000, "partial": False,
    "tmux": {"sessions": [{"name": "work", "attached": 1, "activity": 1756799990}],
             "windows": [{"id": "@7", "name": "claude", "active": True,
                          "activity": 1756799990, "waiting_since": None, "command": "node"},
                         {"id": "@8", "name": "shell", "active": False,
                          "activity": 1756790000, "waiting_since": 1756795000, "command": "bash"}]},
    "agents": [{"cli": "claude", "pid": 4242, "started": 1756790000, "cwd": "/workspaces/foo"}],
    "git": {"root": "/workspaces/foo", "branch": "feat/x", "head": "abc1234",
            "dirty": True, "ahead": 2, "behind": 0},
    "cgroup": {"mem_current": 1234, "mem_max": 8589934592, "cpu_usec": 1, "nr_procs": 42},
}


class ProbeContainer:
    def __init__(self, exit_code=0, stdout=b"", cmds=None):
        self.id = "c1"
        self.status = "running"
        self._exit = exit_code
        self._stdout = stdout
        self.cmds = cmds if cmds is not None else []

    def exec_run(self, cmd, demux=False):
        self.cmds.append(cmd)
        return FakeExecResult(self._exit, self._stdout)


def test_parse_good_report_and_helpers():
    r = ProbeReport.model_validate(GOOD)
    assert r.schema_ == 1
    assert r.work_activity() == 1756799990
    assert r.work_attached() == 1
    wins = r.work_windows()
    assert [w.window_id for w in wins] == ["@7", "@8"]
    assert wins[1].waiting_since == 1756795000 and wins[1].command == "bash"
    assert r.agents[0].cli == "claude"
    assert r.git.branch == "feat/x"


def test_null_sections_are_fine():
    r = ProbeReport.model_validate({"schema": 1, "ts": 1, "tmux": None, "agents": None,
                                    "git": None, "cgroup": None})
    assert r.work_activity() == -1 and r.work_attached() == 0 and r.work_windows() == []


def test_unknown_keys_ignored_and_wrong_types_rejected():
    ProbeReport.model_validate({**GOOD, "surprise": {"x": 1}})
    with pytest.raises(Exception):
        ProbeReport.model_validate({**GOOD, "agents": [{"cli": "claude", "pid": "not-int"}]})


def test_list_and_string_caps():
    too_many = {**GOOD, "agents": [{"cli": "claude", "pid": i} for i in range(65)]}
    with pytest.raises(Exception):
        ProbeReport.model_validate(too_many)
    long_name = {**GOOD, "git": {**GOOD["git"], "branch": "b" * 513}}
    with pytest.raises(Exception):
        ProbeReport.model_validate(long_name)


def test_run_probe_execs_dvw_probe_and_parses():
    c = ProbeContainer(0, json.dumps(GOOD).encode())
    r = run_probe(c)
    assert r is not None and r.work_attached() == 1
    assert c.cmds == [["dvw-probe"]]


@pytest.mark.parametrize("code", [126, 127])
def test_run_probe_missing_raises(code):
    with pytest.raises(ProbeMissing):
        run_probe(ProbeContainer(code, b"exec: dvw-probe: not found"))


def test_run_probe_other_failures_return_none():
    assert run_probe(ProbeContainer(1, b"boom")) is None
    assert run_probe(ProbeContainer(0, b"not json")) is None
    assert run_probe(ProbeContainer(0, b"x" * (MAX_OUTPUT + 1))) is None
    assert run_probe(ProbeContainer(0, json.dumps({"schema": 2, "ts": 1}).encode())) is None


def test_run_probe_exec_exception_returns_none():
    class Boom(ProbeContainer):
        def exec_run(self, cmd, demux=False):
            raise RuntimeError("docker down")
    assert run_probe(Boom()) is None
```

- [ ] **Step 2: Run to verify failure**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_probe.py`
Expected: `ModuleNotFoundError: No module named 'app.probe'`.

- [ ] **Step 3: Write `app/probe.py`**

```python
"""dvw-probe output as untrusted input.

The catalog runs `dvw-probe` inside each workspace container (one exec, via
the docker proxy) and gets back one JSON document. The container may be
hostile, so everything here is bounded: output size, list lengths, string
lengths, and the schema version. Parsing failures never propagate; callers
get None and log once.
"""

from __future__ import annotations

import json
import logging

from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from typing_extensions import Annotated

from .models import WindowInfo

log = logging.getLogger(__name__)

MAX_OUTPUT = 256 * 1024
SCHEMA = 1

Str = Annotated[str, StringConstraints(max_length=512)]


class ProbeSession(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: Str
    attached: int = 0
    activity: int = -1


class ProbeWindow(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: Str
    name: Str
    active: bool = False
    activity: int = -1
    waiting_since: int | None = None
    command: Str = ""


class ProbeTmux(BaseModel):
    model_config = ConfigDict(extra="ignore")
    sessions: list[ProbeSession] = Field(default_factory=list, max_length=64)
    windows: list[ProbeWindow] = Field(default_factory=list, max_length=256)


class ProbeAgent(BaseModel):
    model_config = ConfigDict(extra="ignore")
    cli: Str
    pid: int
    started: int | None = None
    cwd: Str | None = None


class ProbeGit(BaseModel):
    model_config = ConfigDict(extra="ignore")
    root: Str | None = None
    branch: Str | None = None
    head: Str | None = None
    dirty: bool | None = None
    ahead: int | None = None
    behind: int | None = None


class ProbeCgroup(BaseModel):
    model_config = ConfigDict(extra="ignore")
    mem_current: int | None = None
    mem_max: int | None = None
    cpu_usec: int | None = None
    nr_procs: int | None = None


class ProbeReport(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)
    schema_: int = Field(alias="schema")
    ts: int
    partial: bool = False
    tmux: ProbeTmux | None = None
    agents: list[ProbeAgent] | None = Field(default=None, max_length=64)
    git: ProbeGit | None = None
    cgroup: ProbeCgroup | None = None

    def work_activity(self) -> int:
        if self.tmux is None:
            return -1
        for s in self.tmux.sessions:
            if s.name == "work":
                return s.activity
        return -1

    def work_attached(self) -> int:
        if self.tmux is None:
            return 0
        for s in self.tmux.sessions:
            if s.name == "work":
                return max(0, s.attached)
        return 0

    def work_windows(self) -> list[WindowInfo]:
        if self.tmux is None:
            return []
        return [
            WindowInfo(window_id=w.id, name=w.name, active=w.active,
                       activity=w.activity, waiting_since=w.waiting_since,
                       command=w.command)
            for w in self.tmux.windows if w.id.startswith("@")
        ]


class ProbeMissing(Exception):
    """dvw-probe is not installed in this container (exec exit 126/127)."""


class ProbeError(Exception):
    pass


def run_probe(container) -> ProbeReport | None:
    try:
        res = container.exec_run(["dvw-probe"], demux=True)
    except Exception as e:
        log.warning("probe exec failed for %s: %s", getattr(container, "id", "?"), e)
        return None
    if res.exit_code in (126, 127):
        raise ProbeMissing(container.id)
    if res.exit_code != 0:
        log.warning("probe exit %s for %s", res.exit_code, container.id)
        return None
    stdout = res.output[0] if isinstance(res.output, tuple) else res.output
    if not stdout or len(stdout) > MAX_OUTPUT:
        log.warning("probe output empty or over %d bytes for %s", MAX_OUTPUT, container.id)
        return None
    try:
        data = json.loads(stdout.decode("utf-8", "replace"))
        report = ProbeReport.model_validate(data)
    except Exception as e:
        log.warning("probe output rejected for %s: %s", container.id, e)
        return None
    if report.schema_ != SCHEMA:
        log.warning("probe schema %s unsupported for %s", report.schema_, container.id)
        return None
    return report
```

If `typing_extensions` is not importable in the catalog venv, use `from typing import Annotated` (Python 3.11+ has it).

- [ ] **Step 4: Run the tests**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_probe.py`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add catalog-service/app/probe.py catalog-service/tests/test_probe.py
git commit -m "$(cat <<'EOF'
feat(catalog): ProbeReport model and run_probe, bounded untrusted input

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 7: docker_inspect: probe first, tmux fallback, one exec per container per request

**Files:**
- Modify: `catalog-service/app/docker_inspect.py`
- Modify: `catalog-service/tests/test_resolver.py` (FakeContainer gains probe support)
- Create: `catalog-service/tests/test_probe_inspect.py`

**Interfaces:**
- Consumes: `run_probe`, `ProbeMissing`, `ProbeReport` from Task 6.
- Produces (on `DockerInspector`):
  - `class Snapshot`: `activity: int`, `attached: int`, `windows: list[WindowInfo]`, `report: ProbeReport | None`, `probe: str` (`ok`, `partial`, `missing`, `failed`).
  - `_snapshot(self, c, memo: dict[str, Snapshot] | None = None) -> Snapshot`.
  - `_tmux_work_activity(c, memo=None)`, `_tmux_work_attached(c, memo=None)`, `_work_session_windows(c, memo=None)` now read from `_snapshot`; the legacy exec implementations are renamed `_legacy_tmux_activity`, `_legacy_tmux_attached`, `_legacy_tmux_windows` and are only called by `_snapshot` when the probe is missing.
  - `status_many`, `windows_many`, `_resolve_candidates` and `siblings` create one `memo = {}` per call and pass it down.

- [ ] **Step 1: Extend the fake container**

In `tests/test_resolver.py` `FakeContainer.__init__`, add parameters `probe=None, probe_exit=None` and store them (`self._probe`, `self._probe_exit`). At the top of `exec_run`, before the `stat` branch:

```python
        if cmd == ["dvw-probe"]:
            if self._probe_exit is not None:
                return FakeExecResult(self._probe_exit, b"")
            if self._probe is None:
                return FakeExecResult(127, b"exec: dvw-probe: not found")
            import json as _json
            return FakeExecResult(0, _json.dumps(self._probe).encode())
```

With `probe=None` and `probe_exit=None` the fake behaves as "probe missing", so every existing test keeps exercising the tmux path unchanged.

- [ ] **Step 2: Write the failing tests**

`catalog-service/tests/test_probe_inspect.py`:

```python
"""docker_inspect uses dvw-probe first and falls back to tmux execs only
when the probe is missing (exit 126/127). One exec per container per call."""

from __future__ import annotations

from app.config import Settings
from app.docker_inspect import DockerInspector
from tests.test_probe import GOOD
from tests.test_resolver import FakeClient, FakeContainer


def _inspector(containers, monkeypatch):
    import app.docker_inspect as di
    monkeypatch.setattr(di.docker, "from_env", lambda timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="", resolve_cache_ttl=0))


def _probe_container(cid="c1", ws="ws-a", **kw):
    return FakeContainer(cid, f"n-{cid}", f"u-{cid}", f"/workspaces/{ws}", probe=GOOD, **kw)


def test_windows_many_uses_probe_once(monkeypatch):
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.attached == 1
    assert [w.window_id for w in ww.windows] == ["@7", "@8"]
    assert ww.windows[1].waiting_since == 1756795000
    execs = [cmd for cmd in c.exec_calls if cmd == ["dvw-probe"]]
    assert len(execs) == 1
    assert not any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_status_many_attached_from_probe(monkeypatch):
    c = _probe_container()
    insp = _inspector([c], monkeypatch)
    (st,) = insp.status_many(["ws-a"])
    assert st.attached == 1
    assert sum(1 for cmd in c.exec_calls if cmd == ["dvw-probe"]) == 1


def test_sibling_tiebreak_uses_probe_activity(monkeypatch):
    quiet = {**GOOD, "tmux": {"sessions": [{"name": "work", "attached": 0, "activity": 10}], "windows": []}}
    a = FakeContainer("c-a", "a", "u-a", "/workspaces/ws-a", probe=quiet)
    b = FakeContainer("c-b", "b", "u-b", "/workspaces/ws-a", probe=GOOD)
    insp = _inspector([a, b], monkeypatch)
    r = insp.resolve("ws-a")
    assert r.container_id == "c-b" and r.tmux_work_activity == 1756799990


def test_probe_missing_falls_back_to_tmux(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=100,
                      tmux_attached=2, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.attached == 2 and ww.windows[0].window_id == "@1"
    assert insp.resolve("ws-a").tmux_work_activity == 100
    assert any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_probe_failure_is_not_a_fallback(monkeypatch):
    # exit 1 means the probe exists but broke: no tmux exec, empty snapshot.
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", probe_exit=1,
                      tmux_work=100, tmux_windows="@1\twork\t1\t5\t\tclaude\t2\n")
    insp = _inspector([c], monkeypatch)
    (ww,) = insp.windows_many()
    assert ww.windows == [] and ww.attached == 0
    assert not any(cmd[0] == "tmux" for cmd in c.exec_calls)


def test_inspect_carries_agents_git_and_probe_state(monkeypatch):
    c = _probe_container()
    c.attrs["Config"] = {"Image": "ghcr.io/x/y@sha256:" + "a" * 64}
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.probe == "ok"
    assert info.agents[0].cli == "claude" and info.agents[0].pid == 4242
    assert info.git.branch == "feat/x" and info.git.dirty is True and info.git.ahead == 2
    assert info.image == "ghcr.io/x/y@sha256:" + "a" * 64


def test_inspect_probe_missing_state(monkeypatch):
    c = FakeContainer("c1", "n1", "u1", "/workspaces/ws-a", tmux_work=1)
    insp = _inspector([c], monkeypatch)
    info = insp.inspect("ws-a")
    assert info.probe == "missing" and info.agents == [] and info.git is None
```

Also add to `FakeContainer.__init__`: `self.exec_calls = []` and at the top of `exec_run`: `self.exec_calls.append(list(cmd))`.

- [ ] **Step 3: Run to verify failure**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_probe_inspect.py`
Expected: failures (`Snapshot` missing, `probe` attribute missing, tmux execs still happening).

- [ ] **Step 4: Implement the snapshot layer**

In `catalog-service/app/docker_inspect.py`:

1. Add imports: `from .probe import ProbeMissing, ProbeReport, run_probe` and `from .models import AgentProc, GitState` (added in Task 8; for this task define them in Task 8 first if you run tasks strictly in order, or add the two models now and let Task 8 wire them into `ContainerInspect`). To keep this task self-contained, add the models now (Task 8 then only extends `ContainerInspect`):

   In `app/models.py` before `class BindMount`:
   ```python
   class AgentProc(BaseModel):
       """A running agent CLI inside the container, from dvw-probe."""

       cli: str
       pid: int
       started: int | None = None
       cwd: str | None = None


   class GitState(BaseModel):
       """Workspace checkout state as seen from inside the container."""

       root: str | None = None
       branch: str | None = None
       head: str | None = None
       dirty: bool | None = None
       ahead: int | None = None
       behind: int | None = None
   ```

2. Add the snapshot type after the `Inspector` protocol:
   ```python
   class Snapshot:
       """Everything one exec tells us about a running container."""

       __slots__ = ("activity", "attached", "windows", "report", "probe")

       def __init__(self, activity=-1, attached=0, windows=None, report=None, probe="failed"):
           self.activity = activity
           self.attached = attached
           self.windows = windows or []
           self.report = report
           self.probe = probe
   ```

3. Rename the three exec methods to `_legacy_tmux_activity`, `_legacy_tmux_attached`, `_legacy_tmux_windows` (bodies unchanged) and add:
   ```python
   def _snapshot(self, c: Container, memo: dict[str, Snapshot] | None = None) -> Snapshot:
       """Probe first; tmux execs only when the probe is not installed.

       memo is per request: status_many/windows_many/resolve pass one dict
       down so a container is exec'd once per call, whatever asks."""
       if memo is not None and c.id in memo:
           return memo[c.id]
       if c.status != "running":
           snap = Snapshot(probe="failed")
       else:
           try:
               report = run_probe(c)
           except ProbeMissing:
               attached, windows = self._legacy_tmux_windows(c)
               snap = Snapshot(
                   activity=self._legacy_tmux_activity(c),
                   attached=attached or self._legacy_tmux_attached(c),
                   windows=windows, report=None, probe="missing",
               )
           else:
               if report is None:
                   snap = Snapshot(probe="failed")
               else:
                   snap = Snapshot(
                       activity=report.work_activity(),
                       attached=report.work_attached(),
                       windows=report.work_windows(),
                       report=report,
                       probe="partial" if report.partial else "ok",
                   )
       if memo is not None:
           memo[c.id] = snap
       return snap

   def _tmux_work_activity(self, c: Container, memo=None) -> int:
       return self._snapshot(c, memo).activity

   def _tmux_work_attached(self, c: Container, memo=None) -> int:
       return self._snapshot(c, memo).attached

   def _work_session_windows(self, c: Container, memo=None) -> tuple[int, list[WindowInfo]]:
       s = self._snapshot(c, memo)
       return s.attached, s.windows
   ```
   In the fallback branch the legacy windows exec already carries `session_attached`, so the attached exec only runs when the windows exec returned nothing. That keeps the missing-probe path at two execs instead of three.

4. Thread a memo through callers:
   - `_resolve_candidates(self, ws_id, cands, *, probe_single_activity=True, memo=None)`: create `memo = {} if memo is None else memo` at the top; pass `memo` to every `_tmux_work_activity(c, memo)` call.
   - `resolve()`: `return self._resolve_candidates(ws_id, self._candidates(ws_id))` unchanged.
   - `siblings()`: `memo = {}` at top, pass to `_tmux_work_activity(c, memo)`.
   - `_attached_many(self, containers, memo)`: signature gains `memo`; `probe()` calls `self._tmux_work_attached(c, memo)`. Note the workers run in threads writing to a shared dict; guard `memo` writes with `result_lock` by passing a per-thread dict instead: simplest is to give each worker its own `{}` and merge nothing (the value is what matters), so call `self._tmux_work_attached(c, {})` inside `probe()` and drop the parameter. Choose this; it keeps the thread model untouched.
   - `status_many()`: `memo: dict[str, Snapshot] = {}`; pass `memo=memo` to `_resolve_candidates(...)`. `_attached_many` runs after resolution and would exec again for the tie-broken containers; to honour "one exec per container", seed the attached map from the memo first:
     ```python
     attached = {cid: s.attached for cid, s in memo.items() if cid in selected_running}
     remaining = [c for c in selected_running.values() if c.id not in attached]
     attached.update(self._attached_many(remaining))
     ```
   - `windows_many()`: `memo = {}`; pass to `_resolve_candidates(..., memo=memo)` and `self._work_session_windows(canonical, memo)`.

5. `inspect()`: after `c.reload()` add `snap = self._snapshot(c)`; set on `info` (fields added in Task 8; add them to `ContainerInspect` now as part of this task, see Task 8 Step 1 for the exact lines, then Task 8 only adds the API test):
   ```python
   info.probe = snap.probe
   if snap.report is not None:
       info.agents = [AgentProc(**a.model_dump()) for a in (snap.report.agents or [])]
       info.git = GitState(**snap.report.git.model_dump()) if snap.report.git else None
       if info.running and info.mem_bytes is None and snap.report.cgroup and snap.report.cgroup.mem_current is not None:
           info.mem_bytes = snap.report.cgroup.mem_current
           info.mem_limit = snap.report.cgroup.mem_max
   ```
   Place this after the `_cpu_mem` block so the stats-derived values win when present.

6. `inspect()` image field: replace
   `image=(c.image.tags or [a.get("Image")])[0] if c.image else a.get("Image"),`
   with
   `image=(a.get("Config") or {}).get("Image") or a.get("Image"),`
   because `c.image` needs `GET /images/{id}/json`, which the proxy denies. `_image_digest` already guards its own `c.image` use.

- [ ] **Step 5: Run the catalog suite**

Run: `cd catalog-service && uv run --extra dev pytest -q`
Expected: all pass, including the existing resolver, windows and waiting tests (they still take the tmux path via the missing-probe fallback).

- [ ] **Step 6: Commit**

```bash
git add catalog-service/app/docker_inspect.py catalog-service/app/models.py \
        catalog-service/tests/test_resolver.py catalog-service/tests/test_probe_inspect.py
git commit -m "$(cat <<'EOF'
feat(catalog): one dvw-probe exec per container per request, tmux fallback

status_many, windows_many and the sibling tie-break share one snapshot
memo per call. Containers without dvw-probe (exit 126/127) take the old
tmux execs; a broken probe is reported as failed, not retried via tmux.
inspect() no longer touches /images for the image ref.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 8: `ContainerInspect` fields and the API surface

**Files:**
- Modify: `catalog-service/app/models.py` (`ContainerInspect`, after `image_current`)
- Modify: `catalog-service/app/config.py:42` (`docker_host` default and comment)
- Modify: `catalog-service/tests/test_workspaces.py` (append an inspect API test)

**Interfaces:**
- Produces: `ContainerInspect.agents: list[AgentProc]`, `ContainerInspect.git: GitState | None`, `ContainerInspect.probe: str = "missing"`; `Settings.docker_host` default `unix:///run/dvw-docker-proxy/docker.sock`.

- [ ] **Step 1: Add the fields**

In `ContainerInspect` after `image_current: bool | None = None`:

```python
    # From dvw-probe (one exec inside the container). probe: ok / partial /
    # missing (container has no dvw-probe yet) / failed (probe broke).
    agents: list[AgentProc] = Field(default_factory=list)
    git: GitState | None = None
    probe: str = "missing"
```

(If Task 7 already added these, skip.)

- [ ] **Step 2: Write the failing API test**

Append to `tests/test_workspaces.py`:

```python
def test_inspect_exposes_agents_git_and_probe(client, inspector):
    from app.models import AgentProc, ContainerInspect, GitState

    inspector.inspections["ws-a"] = ContainerInspect(
        workspace_id="ws-a", container_id="c1", running=True, liveness="alive",
        probe="ok",
        agents=[AgentProc(cli="claude", pid=42, started=1756790000, cwd="/workspaces/ws-a")],
        git=GitState(root="/workspaces/ws-a", branch="feat/x", head="abc1234",
                     dirty=True, ahead=2, behind=0),
    )
    body = client.get("/v1/workspaces/ws-a/inspect").json()
    assert body["probe"] == "ok"
    assert body["agents"] == [{"cli": "claude", "pid": 42, "started": 1756790000,
                               "cwd": "/workspaces/ws-a"}]
    assert body["git"]["branch"] == "feat/x" and body["git"]["ahead"] == 2


def test_inspect_defaults_when_probe_missing(client, inspector):
    body = client.get("/v1/workspaces/ws-zzz/inspect").json()
    assert body["probe"] == "missing" and body["agents"] == [] and body["git"] is None
```

- [ ] **Step 3: Run to verify failure, then pass**

Run: `cd catalog-service && uv run --extra dev pytest -q tests/test_workspaces.py`
Expected: fails on `KeyError: 'probe'` before Step 1, passes after.

- [ ] **Step 4: Change the docker_host default**

In `app/config.py`, replace the `docker_host` comment block and default with:

```python
    # Docker connection. The deployed posture is dvw-docker-proxy on a unix
    # socket that systemd creates with mode 0600 for the catalog user
    # (deploy/dvw-docker-proxy.socket); the service itself has no docker
    # group membership and no TCP. Set CATALOG_DOCKER_HOST to
    # unix:/var/run/docker.sock only for local development with docker-group
    # access. Empty is no longer a supported value.
    docker_host: str = "unix:///run/dvw-docker-proxy/docker.sock"
```

In `docker_inspect.py` `__init__`, replace the `if settings.docker_host: ... else: docker.from_env(...)` with:

```python
        self._client = docker.DockerClient(
            base_url=settings.docker_host, timeout=settings.docker_timeout
        )
```

Then fix the tests that monkeypatch `docker.from_env`: in `tests/test_resolver.py`, `tests/test_windows.py`, `tests/test_waiting.py`, `tests/test_probe_inspect.py` and `tests/test_image_current.py` (grep for `from_env`), change the `_inspector` helper to

```python
    monkeypatch.setattr(di.docker, "DockerClient", lambda base_url=None, timeout=None: FakeClient(containers))
    return DockerInspector(Settings(docker_host="unix:/nonexistent", resolve_cache_ttl=0))
```

and in `tests/conftest.py` `settings` fixture set `docker_host="unix:/nonexistent"`.

- [ ] **Step 5: Run the catalog suite**

Run: `cd catalog-service && uv run --extra dev pytest -q`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add catalog-service/app/models.py catalog-service/app/config.py catalog-service/app/docker_inspect.py catalog-service/tests
git commit -m "$(cat <<'EOF'
feat(catalog): inspect exposes agents, git and probe state; proxy socket is the default

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 9: TUI inspect pane: agents and git lines

**Files:**
- Modify: `tui/dvw_tui/render.py` (`inspect_lines`, new helpers)
- Modify: `tui/tests/test_render.py` (append)

**Interfaces:**
- Produces: `agents_line(agents: list[dict], now: int) -> str`, `git_line(git: dict | None) -> str`; `inspect_lines(data, now=None)` adds `("agents", ...)` and `("git", ...)` after `("disk", ...)` and before the mounts. `screens/main.py` already calls `inspect_lines(data)`; the new `now` parameter defaults to `int(time.time())`.

- [ ] **Step 1: Write the failing tests**

Append to `tui/tests/test_render.py` (add `agents_line, git_line, inspect_lines` to the import list):

```python
def test_agents_line_lists_cli_age_and_cwd():
    now = 1756800000
    agents = [{"cli": "claude", "pid": 1, "started": now - 7800, "cwd": "/workspaces/foo"},
              {"cli": "codex", "pid": 2, "started": now - 300, "cwd": None}]
    assert agents_line(agents, now) == "claude (2h, /workspaces/foo), codex (5m)"


def test_agents_line_none_and_unknown_start():
    assert agents_line([], 0) == "none"
    assert agents_line([{"cli": "claude", "pid": 1, "started": None, "cwd": None}], 0) == "claude"


def test_git_line_formats_branch_counts_and_dirty():
    assert git_line({"branch": "feat/x", "ahead": 2, "behind": 0, "dirty": True}) == "feat/x +2 -0 dirty"
    assert git_line({"branch": "main", "ahead": None, "behind": None, "dirty": False}) == "main clean"
    assert git_line(None) == "unknown"
    assert git_line({"branch": None, "head": "abc1234", "dirty": None}) == "abc1234"


def test_inspect_lines_include_agents_and_git():
    data = {"agents": [{"cli": "claude", "pid": 1, "started": None, "cwd": None}],
            "git": {"branch": "feat/x", "ahead": 1, "behind": 3, "dirty": False},
            "bind_mounts": [{"source": "/a", "destination": "/b", "rw": True}]}
    labels = [k for k, _ in inspect_lines(data, now=0)]
    assert labels.index("agents") < labels.index("mount")
    assert dict(inspect_lines(data, now=0))["agents"] == "claude"
    assert dict(inspect_lines(data, now=0))["git"] == "feat/x +1 -3 clean"
```

- [ ] **Step 2: Run to verify failure**

Run: `cd tui && uv run --group dev pytest -q tests/test_render.py`
Expected: `ImportError: cannot import name 'agents_line'`.

- [ ] **Step 3: Implement**

In `render.py` add `import time` and, before `inspect_lines`:

```python
def agents_line(agents: list[dict], now: int) -> str:
    """'claude (2h, /workspaces/foo), codex (5m)' or 'none'."""
    if not agents:
        return "none"
    parts = []
    for a in agents:
        details = []
        if a.get("started") is not None:
            details.append(age(int(a["started"]), now))
        if a.get("cwd"):
            details.append(a["cwd"])
        parts.append(f"{a.get('cli', '?')} ({', '.join(details)})" if details else a.get("cli", "?"))
    return ", ".join(parts)


def git_line(git: dict | None) -> str:
    """'feat/x +2 -0 dirty' / 'main clean' / 'abc1234' / 'unknown'."""
    if not git:
        return "unknown"
    name = git.get("branch") or git.get("head")
    if not name:
        return "unknown"
    out = [name]
    if git.get("ahead") is not None and git.get("behind") is not None:
        out.append(f"+{git['ahead']} -{git['behind']}")
    if git.get("dirty") is True:
        out.append("dirty")
    elif git.get("dirty") is False:
        out.append("clean")
    return " ".join(out)
```

Change `def inspect_lines(data: dict) -> list[tuple[str, str]]:` to `def inspect_lines(data: dict, now: int | None = None) -> list[tuple[str, str]]:` and, after the `("disk", ...)` pair inside the list, add

```python
        ("agents", agents_line(data.get("agents") or [], now if now is not None else int(time.time()))),
        ("git", git_line(data.get("git"))),
```

- [ ] **Step 4: Run the TUI suite**

Run: `cd tui && uv run --group dev pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tui/dvw_tui/render.py tui/tests/test_render.py
git commit -m "$(cat <<'EOF'
feat(tui): inspect pane shows running agents and git state from dvw-probe

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 10: Deploy: units, user, installer, updater, remove tecnativa

**Files:**
- Create: `catalog-service/deploy/dvw-docker-proxy.socket`
- Create: `catalog-service/deploy/dvw-docker-proxy.service`
- Create: `catalog-service/deploy/docker-proxy.md`
- Modify: `catalog-service/deploy/host-install.sh` (steps 5 to 8)
- Modify: `catalog-service/deploy/host-update.sh` (unit loop, restart, smoke)
- Modify: `catalog-service/deploy/dvw-catalog.service:60-66` (comment and `RestrictAddressFamilies`)
- Modify: `catalog-service/deploy/catalog.env.example:8-10`
- Delete: `catalog-service/deploy/docker-proxy.compose.yml`, `catalog-service/deploy/docker-socket-proxy.md`
- Modify: `tests/bats/deploy-docker-coupling.bats`, `tests/bats/deploy-restart.bats` if they assert on the compose file or `2375` (grep first).

**Interfaces:**
- Produces: units named `dvw-docker-proxy.socket` and `dvw-docker-proxy.service`; system user `dvw-proxy`; catalog env `CATALOG_DOCKER_HOST=unix:///run/dvw-docker-proxy/docker.sock`; sudoers drop-in extended.

- [ ] **Step 1: Check the existing deploy bats for coupling**

Run: `grep -n '2375\|compose\|docker-socket-proxy\|docker-proxy' tests/bats/deploy-*.bats`
Note every assertion; they are updated in Step 6.

- [ ] **Step 2: Write the units**

`catalog-service/deploy/dvw-docker-proxy.socket`:

```ini
[Unit]
Description=dvw docker proxy listener (unix socket for the catalog service only)
Documentation=https://github.com/vossiman/dvw

[Socket]
# systemd owns the socket: it exists from boot, survives proxy restarts, and
# carries the only access control there is. SocketUser/SocketGroup default to
# vossi and are rendered to the installing account by host-install.sh, the
# same way dvw-catalog.service's User= is.
ListenStream=/run/dvw-docker-proxy/docker.sock
SocketUser=vossi
SocketGroup=vossi
SocketMode=0600
DirectoryMode=0755
RemoveOnStop=true

[Install]
WantedBy=sockets.target
```

`catalog-service/deploy/dvw-docker-proxy.service`:

```ini
[Unit]
Description=dvw docker proxy (route allowlist in front of docker.sock)
Documentation=https://github.com/vossiman/dvw
Requires=dvw-docker-proxy.socket docker.service
After=docker.service

[Service]
Type=exec
# Dedicated system user, created by host-install.sh. It is the only non-root
# member of the docker group on the box; the catalog service user is not.
User=dvw-proxy
Group=dvw-proxy
SupplementaryGroups=docker
ExecStart=/usr/bin/python3 /opt/dvw-catalog/proxy/dvw_docker_proxy.py
Environment=PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=2

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Rewrite the installer steps**

In `host-install.sh`, replace everything from `echo "==> 6/8 docker-socket-proxy ...` through `echo "==> proxy healthy"` with:

```bash
echo "==> 6/8 dvw-docker-proxy (system user + socket-activated unit)"
PROXY_SOCK="/run/dvw-docker-proxy/docker.sock"
if ! id dvw-proxy >/dev/null 2>&1; then
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups docker dvw-proxy
fi
# Retire the tecnativa compose proxy if a previous install left it running.
# The compose file is gone from the checkout, so address the container by
# the name compose gave it (project "deploy", service "docker-proxy").
if command -v docker >/dev/null 2>&1 && \
   docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'deploy-docker-proxy-1'; then
  echo "    removing the retired tecnativa docker-socket-proxy container"
  docker rm -f deploy-docker-proxy-1 >/dev/null
fi
# Point the catalog at the proxy socket. Rewrite a tcp:// value left by the
# previous proxy; add the key when it is missing; leave any other value alone.
if grep -q '^CATALOG_DOCKER_HOST=tcp://' "$SVC_DIR/catalog.env"; then
  sed -i "s|^CATALOG_DOCKER_HOST=tcp://.*|CATALOG_DOCKER_HOST=unix://$PROXY_SOCK|" "$SVC_DIR/catalog.env"
elif ! grep -q '^CATALOG_DOCKER_HOST=' "$SVC_DIR/catalog.env"; then
  printf '\nCATALOG_DOCKER_HOST=unix://%s\n' "$PROXY_SOCK" >> "$SVC_DIR/catalog.env"
fi
```

Then change the unit loop in step 7 to render the socket unit too:

```bash
RUN_GROUP="$(id -gn)"
render_unit() {  # $1 = unit file; renders User/Group and SocketUser/SocketGroup
  sed -e "s/^User=vossi$/User=$USER/" -e "s/^Group=vossi$/Group=$RUN_GROUP/" \
      -e "s/^SocketUser=vossi$/SocketUser=$USER/" -e "s/^SocketGroup=vossi$/SocketGroup=$RUN_GROUP/" \
      "$SVC_DIR/deploy/$1"
}
for u in dvw-catalog.service dvw-catalog-backup.service dvw-catalog-backup.timer \
         dvw-docker-proxy.socket dvw-docker-proxy.service; do
  render_unit "$u" | sudo install -m 0644 /dev/stdin "/etc/systemd/system/$u"
done
```

Extend the sudoers heredoc line to:

```
$USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart dvw-catalog.service, /usr/bin/systemctl status dvw-catalog.service, /usr/bin/systemctl reenable dvw-catalog.service, /usr/bin/systemctl daemon-reload, /usr/bin/systemctl restart dvw-docker-proxy.socket, /usr/bin/systemctl restart dvw-docker-proxy.service, /usr/bin/systemctl status dvw-docker-proxy.service
```

After `sudo systemctl daemon-reload` and before `sudo systemctl reenable dvw-catalog.service`, add:

```bash
sudo systemctl reenable dvw-docker-proxy.socket
sudo systemctl restart dvw-docker-proxy.socket
echo "==> waiting for the proxy socket to answer"
proxy_ok=""
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 --unix-socket "$PROXY_SOCK" http://localhost/_ping >/dev/null 2>&1; then
    proxy_ok=1; break
  fi
  sleep 1
done
if [[ -z "$proxy_ok" ]]; then
  echo "ERROR: dvw-docker-proxy did not answer on $PROXY_SOCK after 30s." >&2
  echo "       sudo systemctl status dvw-docker-proxy.socket dvw-docker-proxy.service" >&2
  echo "       journalctl -xeu dvw-docker-proxy.service | tail -50" >&2
  exit 1
fi
echo "==> proxy healthy"
```

Also update the header comment lines that mention the compose proxy (the NOTE about docker CLI access is no longer true: only the one-time retirement step uses docker, and it is guarded). Replace the step-6 comment block with two lines saying the proxy runs as `dvw-proxy` and the installer needs no docker access.

- [ ] **Step 4: Update `host-update.sh`**

Replace the unit loop with the same `render_unit` function and five-unit list; track `proxy_changed=1` when either proxy unit was reinstalled. After the `if [ "$changed" = 1 ]` block add:

```bash
if [ "${proxy_changed:-0}" = 1 ]; then
  if ! sudo -n systemctl restart dvw-docker-proxy.socket >/dev/null 2>&1; then
    echo "WARN: could not restart dvw-docker-proxy.socket without a password." >&2
    echo "      Run once:  sudo systemctl restart dvw-docker-proxy.socket" >&2
    echo "      (or re-run host-install.sh to refresh the sudoers drop-in)" >&2
  fi
fi
```

In the smoke test, before the catalog loop, add a proxy check that fails loudly with a hint to run `host-install.sh` when the socket is absent (a host that never ran the new installer has no `dvw-proxy` user):

```bash
PROXY_SOCK="/run/dvw-docker-proxy/docker.sock"
if [ ! -S "$PROXY_SOCK" ]; then
  echo "smoke test FAILED: $PROXY_SOCK is missing." >&2
  echo "  This host has not run the new installer yet. Run once:" >&2
  echo "  $SVC_DIR/deploy/host-install.sh" >&2
  exit 1
fi
curl -fsS --max-time 2 --unix-socket "$PROXY_SOCK" http://localhost/_ping >/dev/null
```

Also: to restart the proxy service itself when only its Python changed (a `git pull` that touches `proxy/dvw_docker_proxy.py` but no unit), add after the unit block:

```bash
if git -C "$CHECKOUT" diff --quiet "HEAD@{1}" HEAD -- catalog-service/proxy 2>/dev/null; then :; else
  sudo -n systemctl restart dvw-docker-proxy.service >/dev/null 2>&1 || \
    echo "WARN: proxy code changed but could not restart dvw-docker-proxy.service without a password." >&2
fi
```

- [ ] **Step 5: Catalog unit, env example, docs**

`dvw-catalog.service`: replace lines 63-66 (the AF_INET comment and value) with

```ini
# AF_UNIX only: the service's own listen socket and the dvw-docker-proxy
# socket. No TCP is needed anywhere.
RestrictAddressFamilies=AF_UNIX
```

Also update the comment block at lines 14-25 ("NO SupplementaryGroups=docker ...") to say the service reaches Docker through `dvw-docker-proxy` on `/run/dvw-docker-proxy/docker.sock` (see `deploy/docker-proxy.md`), keep the sentence that the group must not be re-added, and drop the paragraph about the loopback TCP port.

`catalog.env.example` lines 8-10:

```
# Docker API endpoint. The service has no docker-group membership; it talks to
# dvw-docker-proxy on a unix socket that systemd creates with mode 0600 for
# the service user (deploy/dvw-docker-proxy.socket, deploy/docker-proxy.md).
CATALOG_DOCKER_HOST=unix:///run/dvw-docker-proxy/docker.sock
```

Delete `docker-proxy.compose.yml` and `docker-socket-proxy.md` with `git rm`. Create `catalog-service/deploy/docker-proxy.md`:

```markdown
# Docker access: dvw-docker-proxy

The catalog service never touches `docker.sock`. It talks to
`dvw-docker-proxy` (`catalog-service/proxy/dvw_docker_proxy.py`) over
`/run/dvw-docker-proxy/docker.sock`, a unix socket systemd creates with mode
0600 for the service user. The proxy runs as the system user `dvw-proxy`, the
only non-root member of the docker group, and forwards exactly these routes:

| Method | Path | Note |
|---|---|---|
| GET | `/_ping`, `/version`, `/info` | docker-py handshake |
| GET | `/containers/json` | list |
| GET | `/containers/{id}/json` | inspect |
| GET | `/containers/{id}/stats?stream=false` | cpu and memory for the inspect view |
| POST | `/containers/{id}/exec` | body must be `Cmd == ["dvw-probe"]` (transitional: `tmux list-sessions` / `list-windows`); no `Privileged`, `Tty`, `AttachStdin`, `User`, `Env`, `WorkingDir` |
| POST | `/exec/{id}/start` | only ids this proxy issued in the last 60 s |
| GET | `/exec/{id}/json` | same |

Everything else is `403` and never reaches dockerd. Every request is logged
to the journal as `verdict=allow|deny method= path=`.

## What this buys

A compromised catalog service can list containers, inspect them, read their
stats, and run `dvw-probe` inside them. It cannot create containers, mount
host paths, pull images, or run any other command. Host-root equivalence is
gone; the previous tecnativa proxy (removed 2026-09) could not do this
because its ACL was path-prefix plus method, so `POST /containers/*/exec`
also allowed `POST /containers/create`.

Access control is the socket's mode bits: only the service user can connect.
The old loopback TCP port had none.

## Adding a route

Add a row to `_ROUTES` in `dvw_docker_proxy.py` with a test in
`tests/test_proxy.py` for both the allowed shape and the nearest denied
neighbour. Prefer extending `dvw-probe` (aiCodingBaseSetup `bin/dvw-probe`)
over adding write routes: the probe runs inside the container and cannot
escalate.

## Migration from tecnativa

Re-run `/opt/dvw/catalog-service/deploy/host-install.sh` once. It creates
`dvw-proxy`, installs and starts the socket unit, rewrites
`CATALOG_DOCKER_HOST` in `catalog.env`, and removes the
`deploy-docker-proxy-1` container. Verify afterwards:

    ss -xl | grep dvw-docker-proxy
    id dvw-proxy
    id vossi | grep -v docker
    curl -fsS --unix-socket /run/dvw-docker-proxy/docker.sock http://localhost/_ping
```

- [ ] **Step 6: Update deploy bats and run them**

For each assertion found in Step 1 that references `2375`, the compose file or `docker-socket-proxy.md`, change it to the new artefact: the socket path `/run/dvw-docker-proxy/docker.sock`, the unit names, `docker-proxy.md`. Add to `tests/bats/deploy-docker-coupling.bats`:

```bash
@test "catalog unit restricts address families to AF_UNIX only" {
  grep -qx 'RestrictAddressFamilies=AF_UNIX' "$DVW_ROOT/catalog-service/deploy/dvw-catalog.service"
}

@test "proxy socket unit is 0600 for the rendered user and the service runs as dvw-proxy in docker group" {
  grep -qx 'SocketMode=0600' "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.socket"
  grep -qx 'SocketUser=vossi' "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.socket"
  grep -qx 'User=dvw-proxy' "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.service"
  grep -qx 'SupplementaryGroups=docker' "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.service"
  ! grep -q 'SupplementaryGroups=docker' "$DVW_ROOT/catalog-service/deploy/dvw-catalog.service"
}

@test "host-install renders SocketUser and installs both proxy units; compose proxy is gone" {
  grep -q 'SocketUser=vossi\$/SocketUser=\$USER' "$DVW_ROOT/catalog-service/deploy/host-install.sh"
  grep -q 'dvw-docker-proxy.socket dvw-docker-proxy.service' "$DVW_ROOT/catalog-service/deploy/host-install.sh"
  grep -q 'useradd --system' "$DVW_ROOT/catalog-service/deploy/host-install.sh"
  [ ! -e "$DVW_ROOT/catalog-service/deploy/docker-proxy.compose.yml" ]
  ! grep -q '2375' "$DVW_ROOT/catalog-service/deploy/host-install.sh"
  ! grep -q '2375' "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}
```

Run: `DVW_ROOT="$PWD" bats tests/bats/deploy-docker-coupling.bats tests/bats/deploy-restart.bats`
Expected: all `ok`. Then `bash -n catalog-service/deploy/host-install.sh catalog-service/deploy/host-update.sh` for syntax.

- [ ] **Step 7: Commit**

```bash
git add -A catalog-service/deploy tests/bats/deploy-docker-coupling.bats tests/bats/deploy-restart.bats
git commit -m "$(cat <<'EOF'
feat(deploy): dvw-docker-proxy units and user replace the tecnativa compose proxy

Socket-activated unix socket at mode 0600 for the catalog user, proxy as
system user dvw-proxy in the docker group, catalog unit AF_UNIX only.
host-install.sh migrates an existing host in one run; host-update.sh
reinstalls the proxy units and restarts the proxy when its code changed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 11: Docker-in-docker end-to-end harness

**Files:**
- Create: `tests/e2e/dind.sh`
- Create: `tests/e2e/workspace.Dockerfile`
- Create: `tests/bats/e2e-dind.bats`

**Interfaces:**
- Consumes: `bin/dvw-probe` from the aicoding worktree (`DVW_PROBE_SRC`, default `/workspaces/devmachine/devpod/aicoding/.claude/worktrees/feat/dvw-probe/bin/dvw-probe`, falling back to `/workspaces/devmachine/devpod/aicoding/bin/dvw-probe`).
- Produces: `tests/e2e/dind.sh [--keep]` exit 0 on success; with `--keep` prints `export DVW_TUI_SOCKET=...` for a playtest and leaves everything running; `tests/e2e/dind.sh --down` tears down a kept run.

- [ ] **Step 1: The workspace image**

`tests/e2e/workspace.Dockerfile`:

```dockerfile
# Throwaway "workspace" for the e2e harness: what dvw-probe expects to find.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends tmux git python3 procps ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 dev \
    && cp /bin/sleep /usr/local/bin/claude
COPY dvw-probe /usr/local/bin/dvw-probe
RUN chmod 0755 /usr/local/bin/dvw-probe
USER dev
WORKDIR /home/dev
# entrypoint: git repo on a branch in the workspace mount, tmux "work" with a
# window running a process named claude, then stay alive.
COPY --chmod=0755 <<'EOF' /usr/local/bin/ws-entrypoint
#!/bin/sh
set -e
WS="$1"
mkdir -p "$WS" && cd "$WS"
if [ ! -d .git ]; then
  git init -q -b main . && git -c user.email=e@e -c user.name=e commit -q --allow-empty -m init
  git switch -q -c feat/e2e && echo x > dirty.txt
fi
tmux new-session -d -s work -n claude -c "$WS" 'exec claude infinity'
tmux new-window -t work -n shell -c "$WS" 'exec sleep infinity'
exec sleep infinity
EOF
ENTRYPOINT ["/usr/local/bin/ws-entrypoint"]
```

If the `COPY --chmod ... <<'EOF'` heredoc form is not accepted by the installed BuildKit, write `ws-entrypoint` as a separate file `tests/e2e/ws-entrypoint` and `COPY` it.

- [ ] **Step 2: The harness**

`tests/e2e/dind.sh`:

```bash
#!/usr/bin/env bash
# End-to-end: dvw-docker-proxy + catalog-service against a docker:dind daemon
# hosting two fake workspace containers with dvw-probe installed. Asserts the
# happy path through the catalog API and the refused attacks straight at the
# proxy socket. Run from the dvw checkout root in the dev container.
#
#   tests/e2e/dind.sh           # run, assert, tear down
#   tests/e2e/dind.sh --keep    # leave running, print the TUI playtest env
#   tests/e2e/dind.sh --down    # tear down a kept run
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
E2E_ROOT="${DVW_E2E_ROOT:-/tmp/dvw-e2e}"
DIND=dvw-e2e-dind
NET=dvw-e2e-net
VOL=dvw-e2e-dind-data
IMG=dvw-e2e-workspace
PROBE_SRC="${DVW_PROBE_SRC:-/workspaces/devmachine/devpod/aicoding/.claude/worktrees/feat/dvw-probe/bin/dvw-probe}"
[ -f "$PROBE_SRC" ] || PROBE_SRC=/workspaces/devmachine/devpod/aicoding/bin/dvw-probe
STATE="$E2E_ROOT/state"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

down() {
  log "teardown"
  if [ -f "$STATE/pids" ]; then xargs -r kill < "$STATE/pids" 2>/dev/null || true; fi
  docker rm -f "$DIND" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -rf "$E2E_ROOT"
}
[ "${1:-}" = "--down" ] && { down; exit 0; }
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
down 2>/dev/null || true
mkdir -p "$STATE" "$E2E_ROOT/ws-a" "$E2E_ROOT/ws-b"
trap '[ $KEEP = 1 ] || down' EXIT

log "docker:dind"
docker network create "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
docker run -d --name "$DIND" --privileged --network "$NET" -e DOCKER_TLS_CERTDIR= \
  -v "$VOL:/var/lib/docker" docker:dind >/dev/null
DIND_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DIND")"
for _ in $(seq 1 60); do
  curl -fsS --max-time 1 "http://$DIND_IP:2375/_ping" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 2 "http://$DIND_IP:2375/_ping" >/dev/null || fail "dind not reachable at $DIND_IP:2375 from this container"
export DOCKER_HOST="tcp://$DIND_IP:2375"

log "workspace image (probe from $PROBE_SRC)"
cp "$PROBE_SRC" tests/e2e/dvw-probe
docker build -q -t "$IMG" -f tests/e2e/workspace.Dockerfile tests/e2e >/dev/null
rm -f tests/e2e/dvw-probe
# The bind-mount source must exist on BOTH sides with the same path: inside
# dind (where the container mounts it) and here (where the catalog checks
# liveness with os.path.isdir).
docker run --rm -v /:/host alpine sh -c "mkdir -p /host$E2E_ROOT/ws-a /host$E2E_ROOT/ws-b" >/dev/null
for ws in ws-a ws-b; do
  docker run -d --name "$ws" --label "dev.containers.id=uid-$ws" \
    -v "$E2E_ROOT/$ws:/workspaces/$ws" "$IMG" "/workspaces/$ws" >/dev/null
done
sleep 2
unset DOCKER_HOST

log "proxy"
DVW_PROXY_LISTEN="$E2E_ROOT/proxy.sock" DVW_PROXY_UPSTREAM="tcp://$DIND_IP:2375" \
  /usr/bin/python3 catalog-service/proxy/dvw_docker_proxy.py 2> "$STATE/proxy.log" &
echo $! >> "$STATE/pids"
for _ in $(seq 1 20); do [ -S "$E2E_ROOT/proxy.sock" ] && break; sleep 0.25; done
curl -fsS --unix-socket "$E2E_ROOT/proxy.sock" http://d/_ping >/dev/null || fail "proxy not answering"

log "catalog"
mkdir -p "$E2E_ROOT/data"
( cd catalog-service && CATALOG_DATA_DIR="$E2E_ROOT/data" \
    CATALOG_DOCKER_HOST="unix://$E2E_ROOT/proxy.sock" CATALOG_BLUEPRINT_IMAGE_TTL=900 \
    uv run uvicorn app.main:app --uds "$E2E_ROOT/catalog.sock" --no-access-log \
    > "$STATE/catalog.log" 2>&1 & echo $! >> "$STATE/pids" )
CAT="curl -fsS --unix-socket $E2E_ROOT/catalog.sock"
for _ in $(seq 1 40); do $CAT http://d/v1/health >/dev/null 2>&1 && break; sleep 0.25; done
$CAT http://d/v1/health | grep -q '"docker":true' || fail "catalog cannot reach docker through the proxy: $($CAT http://d/v1/health || true)"
for ws in ws-a ws-b; do
  $CAT -X POST -H 'Content-Type: application/json' \
    -d "{\"id\":\"$ws\",\"repo\":\"git@github.com:vossiman/$ws.git\",\"branch\":\"main\"}" \
    http://d/v1/workspaces >/dev/null
done

log "assert: happy path"
status="$($CAT http://d/v1/containers/status)"
echo "$status" | python3 -c '
import json,sys; s={x["id"]:x for x in json.load(sys.stdin)}
assert s["ws-a"]["liveness"]=="alive" and s["ws-b"]["liveness"]=="alive", s
assert s["ws-a"]["container_id"], s'
windows="$($CAT http://d/v1/containers/windows)"
echo "$windows" | python3 -c '
import json,sys; w={x["workspace_id"]:x for x in json.load(sys.stdin)}
names={x["name"] for x in w["ws-a"]["windows"]}
assert {"claude","shell"} <= names, w
assert all(x["activity"]>0 for x in w["ws-a"]["windows"]), w'
inspect="$($CAT http://d/v1/workspaces/ws-a/inspect)"
echo "$inspect" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["probe"]=="ok", d["probe"]
assert d["agents"] and d["agents"][0]["cli"]=="claude", d["agents"]
assert d["git"]["branch"]=="feat/e2e" and d["git"]["dirty"] is True, d["git"]
assert d["running"] is True, d'
grep -q 'cmd=dvw-probe' "$STATE/proxy.log" || fail "proxy never saw the probe exec"
grep -q 'cmd=tmux' "$STATE/proxy.log" && fail "catalog fell back to tmux although the probe is installed"

log "assert: waiting marker after agent-notify inside the container"
DOCKER_HOST="tcp://$DIND_IP:2375" docker exec ws-a tmux set-option -w -t work:claude @waiting 1756795000
$CAT http://d/v1/containers/waiting | grep -q '"window_name":"claude"' || fail "waiting window not reported"

log "assert: attacks at the proxy socket are refused"
PX="curl -s -o /dev/null -w %{http_code} --unix-socket $E2E_ROOT/proxy.sock"
CID="$(echo "$status" | python3 -c 'import json,sys; print({x["id"]:x for x in json.load(sys.stdin)}["ws-a"]["container_id"])')"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Image":"alpine","HostConfig":{"Binds":["/:/host"]}}' http://d/containers/create)" = 403 ] || fail "create not refused"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Cmd":["sh"],"AttachStdout":true}' "http://d/containers/$CID/exec")" = 403 ] || fail "exec sh not refused"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Cmd":["dvw-probe"],"Privileged":true,"AttachStdout":true}' "http://d/containers/$CID/exec")" = 403 ] || fail "privileged exec not refused"
[ "$($PX http://d/images/json)" = 403 ] || fail "images not refused"
[ "$($PX -X POST -d '{}' http://d/exec/0000000000000000000000000000000000000000000000000000000000000000/start)" = 403 ] || fail "fabricated exec id not refused"
[ "$($PX -X DELETE "http://d/containers/$CID")" = 403 ] || fail "delete not refused"
[ "$(grep -c 'verdict=deny' "$STATE/proxy.log")" -ge 6 ] || fail "expected at least 6 deny lines in the proxy log"
DOCKER_HOST="tcp://$DIND_IP:2375" docker ps -a --format '{{.Names}}' | grep -qx ws-a || fail "workspace container vanished"
[ "$(DOCKER_HOST="tcp://$DIND_IP:2375" docker ps -aq | wc -l)" = 2 ] || fail "an attack created a container"

log "e2e ok"
if [ $KEEP = 1 ]; then
  cat <<EOF

kept running. TUI playtest:
  export DVW_TUI_SOCKET=$E2E_ROOT/catalog.sock
  (cd tui && uv run python -m dvw_tui.app)
  # flag a window as waiting:  DOCKER_HOST=tcp://$DIND_IP:2375 docker exec ws-b tmux set-option -w -t work:claude @waiting \$(date +%s)
tear down with: tests/e2e/dind.sh --down
EOF
fi
```

Check how the TUI reads its socket (`grep -n 'DVW_TUI_SOCKET\|environ' tui/dvw_tui/app.py tui/dvw_tui/client.py`) and adjust the printed playtest env if the variable name differs. Check `lib/tui-launch.sh` for the exact module invocation and mirror it.

`chmod +x tests/e2e/dind.sh`.

- [ ] **Step 3: bats wrapper**

`tests/bats/e2e-dind.bats`:

```bash
#!/usr/bin/env bats
# Opt-in end-to-end run against docker:dind. Skipped unless DVW_E2E=1 so the
# normal suite stays fast and offline.

@test "e2e: proxy + catalog + probe against docker-in-docker" {
  [ "${DVW_E2E:-}" = "1" ] || skip "set DVW_E2E=1 to run the dind harness"
  run bash "$DVW_ROOT/tests/e2e/dind.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"e2e ok"* ]]
}
```

- [ ] **Step 4: Run it**

Run: `tests/e2e/dind.sh`
Expected: ends with `==> e2e ok`. Typical first-run problems and their fixes:
- `dind not reachable`: this dev container is not on the default bridge with the dind container. Attach the dev container's network instead: replace `--network "$NET"` by `--network container:$(hostname)` is NOT possible for dind (it needs its own netns for port 2375 not to clash), so instead publish the port on the docker host and reach it via the host gateway: `-p 127.0.0.1:0:2375` plus `DIND_IP=$(ip route | awk '/default/{print $3}')` and the mapped port from `docker port "$DIND" 2375`. Try the bridge IP first; keep whichever works and note it in the script header.
- `catalog cannot reach docker`: read `$STATE/catalog.log`; a `403` on `/version` means docker-py negotiated a route the table lacks; add it to `_ROUTES` with a proxy test.
- `probe never seen`: `docker exec ws-a dvw-probe` inside dind by hand and read the output.

- [ ] **Step 5: Playtest**

Run: `tests/e2e/dind.sh --keep`, then in another terminal follow the printed env and launch the TUI. Check: two workspaces listed as running, expanding shows `claude` and `shell` windows with an age, the inspect pane shows `agents: claude (...)` and `git: feat/e2e dirty`, and after flagging a window via the printed `docker exec` line the waiting marker appears on the next refresh. Then `tests/e2e/dind.sh --down`. Record what you saw in the Task 12 results.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e tests/bats/e2e-dind.bats
git commit -m "$(cat <<'EOF'
test(e2e): docker-in-docker harness for proxy, probe and catalog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
```

### Task 12: Full verification and results record

**Files:**
- Modify: `docs/superpowers/plans/2026-09-01-docker-proxy-probe.md` (this file, append a "Results" section)

- [ ] **Step 1: Run every suite**

```bash
cd "$DVW"/catalog-service && uv run --extra dev pytest -q
cd "$DVW"/tui && uv run --group dev pytest -q
cd "$DVW" && tests/bats/run.sh
cd "$DVW" && DVW_E2E=1 DVW_ROOT="$PWD" bats tests/bats/e2e-dind.bats
cd "$AIC" && tests/bats/run.sh
cd "$DVW" && git status --short   # must be empty: no .pyc, no leftover tests/e2e/dvw-probe
grep -rn '—' "$DVW"/catalog-service/proxy "$DVW"/catalog-service/app/probe.py "$DVW"/catalog-service/deploy/docker-proxy.md "$DVW"/tests/e2e "$AIC"/bin/dvw-probe && echo "em dash found" || echo "no em dashes"
```

- [ ] **Step 2: Append results**

Under a `## Results` heading at the end of this plan, record the pass counts per suite, the e2e log tail, and the playtest observations (what the tree and inspect pane showed). Then:

```bash
git add docs/superpowers/plans/2026-09-01-docker-proxy-probe.md
git commit -m "$(cat <<'EOF'
docs: record verification results for the docker proxy and probe plan

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D7FagRgfSPYeZ5FB6hGt7T
EOF
)"
git push -u origin feat/docker-proxy-probe
```

PR creation, ticket comments and the vossisrv rollout are outside this plan (see the spec's Rollout section and the session's task list).

## Results

Verified 2026-09-02. `$DVW` = `devpod/dvw` worktree on `feat/docker-proxy-probe`,
`$AIC` = `devpod/aicoding` worktree on `feat/dvw-probe`.

### Suite pass counts

| Suite | Command | Result |
|---|---|---|
| catalog-service pytest | `cd "$DVW"/catalog-service && uv run --extra dev pytest -q` | 280 passed, 1 warning (starlette/httpx deprecation, pre-existing) |
| tui pytest | `cd "$DVW"/tui && uv run --group dev pytest -q` | 220 passed |
| dvw bats | `cd "$DVW" && tests/bats/run.sh` | 530 passed, 0 failed (`1..530`) |
| e2e-dind bats | `cd "$DVW" && DVW_E2E=1 DVW_ROOT="$PWD" bats tests/bats/e2e-dind.bats` | 1 passed, 0 failed |
| aicoding bats | `cd "$AIC" && tests/bats/run.sh` | 638 passed, 0 failed (`1..638`) |

### e2e log tail

```
1..1
ok 1 e2e: proxy + catalog + probe against docker-in-docker
```

The full run (not `--keep`) logs `==> assert: happy path`, `==> assert: waiting
marker after agent-notify inside the container`, `==> assert: attacks at the
proxy socket are refused`, then `==> e2e ok` before the single bats `ok 1`
line. It exercises: proxy-mediated `/containers/json`, `/containers/{id}/json`,
`/containers/{id}/stats`, `dvw-probe` exec/start against a real dockerd inside
docker-in-docker; the catalog's `inspect` endpoint reading probe output
(agents, git, mounts); a `tmux set-option @waiting` marker surfacing through
`/v1/containers/waiting`; and six-plus `verdict=deny` proxy log lines for
`POST /containers/create`, non-probe exec, a privileged exec, `/images/json`,
a fabricated exec id, and `DELETE /containers/{id}`, all refused with `403`,
with the workspace container count unchanged (2) after the attack attempts.

### Playtest observations

Re-ran `tests/e2e/dind.sh --keep` to inspect the live catalog + proxy +
docker-in-docker stack, then rendered the real API responses through
`tui/dvw_tui/render.py`'s own functions (`inspect_lines`, `window_label`)
rather than eyeballing raw JSON.

Workspace tree, built from `/v1/containers/status` + `/v1/containers/windows`:

```
ws-b  [alive]
   claude  -> claude  0m
   shell   -> sleep *  0m
ws-a  [alive]
   claude  -> claude  0m  (waiting badge shown; waiting_since is a fixed
                            fixture timestamp from the bats happy-path test,
                            so age() renders it as a large "waiting Nd")
   shell   -> sleep *  0m
```

Both workspaces show `liveness: alive`; `ws-a`'s `claude` window carries the
`waiting_since` marker set earlier by the bats happy-path assertion
(`tmux set-option -w -t work:claude @waiting <epoch>`), and `window_label`
renders it with a waiting indicator, confirming the marker survives from
proxy-relayed tmux exec through to the render layer.

Inspect pane for `ws-a`, via `GET /v1/workspaces/ws-a/inspect` rendered
through `inspect_lines`:

```
container: ws-a
status: running
health: -
image: dvw-e2e-<pid>-workspace
started: 2026-09-02T00:14:00.443553685Z
restarts: 0
cpu: 0%
memory: 0%   2.1 MiB / 31.0 GiB
disk: 0 B
agents: claude (0m, /workspaces/ws-a)
git: feat/e2e dirty
mount: /tmp/dvw-e2e-<pid>/ws-a -> /workspaces/ws-a (rw)
```

`probe: ok` in the raw JSON (not part of `inspect_lines`'s own tuple list,
consumed by the caller) confirms the catalog reached `dvw-probe` through the
proxy rather than falling back to the legacy tmux path; the proxy log had no
`cmd=tmux` line for this run, only `cmd=dvw-probe`. Torn back down with
`tests/e2e/dind.sh --down` after capture.

### Clean-tree check

`git status --short` was empty in both `$DVW` and `$AIC` after each test run,
once `clipd/__pycache__/dvw-clipd.cpython-314.pyc` (bytecode cache tracked in
`$DVW`, dirtied by every pytest/bats run, unrelated to this branch) was
checked out back to its committed content, and a stray untracked
`$AIC/bin/__pycache__/` (bytecode cache from running `bin/dvw-probe` locally,
not tracked, not part of any suite's expected output) was removed.

### Em dash check

Ran the brief's grep plus an extended pass over every file this branch added
or changed (`git diff --name-only origin/main...HEAD` in both repos):
no line *added* by this branch introduces a new em dash. Exactly one added
line contains the character at all, and it is not prose: the Step 1 shell
command above, whose grep pattern is the literal character it searches for.
Re-check with `git diff origin/main...HEAD | grep '^+[^+]'` piped through a
grep for that character. Full-file greps over the touched files turn up
plenty of pre-existing em dashes (code comments, docstrings, and the
placeholder glyphs `tui/dvw_tui/render.py` renders for missing values) that
predate this branch and are out of scope.

### Doc sweep

- `catalog-service/README.md:206` used to say "see
  `deploy/docker-socket-proxy.md`" and described dropping the docker group via
  that (deleted) proxy. Rewritten to point at `deploy/docker-proxy.md` and
  describe the `dvw-docker-proxy` unix-socket setup in two sentences.
- `docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md` Component 4:
  the example `agents:` line used a two-unit age (`2h 10m`); `render.py`'s
  `age()` helper only ever renders one unit, so the example now reads
  `agents: claude (2h, /workspaces/foo), codex (5m)`.
- Grepped the whole `$DVW` tree (excluding `.git`, `.superpowers`, `.venv`,
  `node_modules`) for `docker-socket-proxy.md`, `docker-proxy.compose.yml`,
  and `tcp://127.0.0.1:2375`. Hits left in place, all historical/behavioral,
  none live pointers to something that still exists:
  - `docs/superpowers/plans/2026-09-01-docker-proxy-probe.md` (multiple):
    the plan describing the migration itself; explicitly allowed.
  - `docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md` line 279
    (Component 5) references `docker-proxy.compose.yml` being torn down
    during install, and line 289 references `docker-socket-proxy.md` being
    rewritten as `docker-proxy.md`. Both are past-tense descriptions of the
    completed rename/deletion, in the same section that already names the
    replacement files; the Problem section itself only mentions
    `127.0.0.1:2375` as the old, now-replaced endpoint, which is explicitly
    allowed.
  - `tests/bats/deploy-docker-coupling.bats:77` asserts
    `[ ! -e ".../docker-proxy.compose.yml" ]`, a regression test that the
    compose file stays deleted, not a reference to a live file.
  - `tests/bats/deploy-proxy.bats:173` sets
    `CATALOG_DOCKER_HOST=tcp://127.0.0.1:2375` on a fixture `catalog.env`
    before running the installer, to assert the installer migrates it to the
    proxy socket. The string is fixture input for a migration test, not a
    stale reference.
  - `catalog-service/deploy/host-install.sh` and `deploy/docker-proxy.md`'s
    migration note carry no matches for the compose filename or the doc
    filename (both were removed from those files already); `docker-proxy.md`
    mentions "the previous tecnativa proxy (removed 2026-09)" and has a
    "Migration from tecnativa" section, which is the allowed migration note.
  - `catalog-service/deploy/docker-socket-proxy.md` itself no longer exists
    (deleted by this branch); no other file references it as a live path.
