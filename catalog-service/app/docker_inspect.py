"""Local Docker inspection — the whole reason the service lives on vossisrv.

Everything dvw used to do over SSH (enumerate containers, match the
/workspaces/<id> bind mount, tie-break siblings by tmux activity, detect
orphans and stale bind mounts) happens here against the local Docker socket,
authoritatively and in milliseconds.

docker-py is synchronous/blocking; callers run these methods in a threadpool
(see app/deps.py) so the event loop is never stalled.
"""

from __future__ import annotations

import grp
import os
import pwd
import re
import subprocess
import threading
import time
from typing import Protocol

import docker
from docker.models.containers import Container

from .config import Settings
from .models import (
    BindMount,
    CanonicalContainer,
    ContainerInspect,
    Orphan,
    SiblingContainer,
    WaitingWindow,
    WindowInfo,
    WorkspaceStatus,
    WorkspaceWindows,
)


def _ws_id_from_mounts(mounts: list[dict], prefix: str) -> str | None:
    # Match ONLY an exact /workspaces/<id> destination (one trailing segment),
    # so this agrees with the resolver's exact-match candidate selection. A
    # nested mount like /workspaces/foo/bar is not a workspace root and is
    # ignored rather than mis-keyed as "foo".
    for m in mounts:
        dest = m.get("Destination", "")
        if dest.startswith(prefix):
            seg = dest[len(prefix):]
            if seg and "/" not in seg:
                return seg
    return None


def _workspace_mount(mounts: list[dict], prefix: str) -> dict | None:
    for m in mounts:
        if m.get("Destination", "").startswith(prefix):
            return m
    return None


_DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def _sha256_of(ref: str | None) -> str | None:
    if not ref:
        return None
    m = _DIGEST_RE.search(ref)
    return m.group(0) if m else None


def image_current(digest: str | None, blueprint_ref: str | None) -> bool | None:
    bp = _sha256_of(blueprint_ref)
    if digest is None or bp is None:
        return None
    return digest == bp


class Inspector(Protocol):
    def ping(self) -> bool: ...
    def resolve(self, ws_id: str) -> CanonicalContainer: ...
    def inspect(
        self, ws_id: str, blueprint_image: str | None = None
    ) -> ContainerInspect: ...
    def status_many(
        self, ids: list[str], blueprint_image: str | None = None
    ) -> list[WorkspaceStatus]: ...
    def siblings(self, ws_id: str) -> list[SiblingContainer]: ...
    def orphans(self, catalog_ids: set[str]) -> list[Orphan]: ...
    def waiting_windows(self) -> list[WaitingWindow]: ...
    def windows_many(self) -> list[WorkspaceWindows]: ...


class DockerInspector:
    # Attached-client metadata is useful but must never make the bulk
    # liveness endpoint wait for Docker's per-call timeout once per workspace.
    # Shared slots bound both fan-out and the number of probes left running
    # after a response has used up its small best-effort budget.
    _attached_probe_workers = 4
    _attached_probe_budget = 0.25

    def __init__(self, settings: Settings):
        self._settings = settings
        if settings.docker_host:
            self._client = docker.DockerClient(
                base_url=settings.docker_host, timeout=settings.docker_timeout
            )
        else:
            self._client = docker.from_env(timeout=settings.docker_timeout)
        self._attached_slots = threading.BoundedSemaphore(
            self._attached_probe_workers
        )

    # ---- helpers ----------------------------------------------------------

    def ping(self) -> bool:
        try:
            return bool(self._client.ping())
        except Exception:
            return False

    def _devpod_containers(self) -> list[Container]:
        return self._client.containers.list(
            all=True, filters={"label": self._settings.devpod_id_label}
        )

    def _target_dest(self, ws_id: str) -> str:
        return f"{self._settings.workspace_mount_prefix}{ws_id}"

    def _candidates(self, ws_id: str) -> list[Container]:
        # Running containers only, matching legacy `docker ps` (no -a): the
        # canonical container for connect/exec is necessarily running, and
        # tmux activity is only meaningful on running containers. (Stopped
        # containers still surface via status_many/orphans, which list all.)
        target = self._target_dest(ws_id)
        out = []
        for c in self._devpod_containers():
            if c.status != "running":
                continue
            mounts = c.attrs.get("Mounts", [])
            if any(m.get("Destination") == target for m in mounts):
                out.append(c)
        return out

    def _tmux_work_activity(self, c: Container) -> int:
        """Epoch activity of the tmux `work` session, or -1 if none/unreadable.

        Mirrors dvw's resolver: `tmux list-sessions -F '#{session_name}
        #{session_activity}'`, take the `work` row, else -1.
        """
        if c.status != "running":
            return -1
        try:
            res = c.exec_run(
                ["tmux", "list-sessions", "-F", "#{session_name} #{session_activity}"],
                demux=True,
            )
        except Exception:
            return -1
        if res.exit_code != 0:
            return -1
        stdout = res.output[0] if isinstance(res.output, tuple) else res.output
        if not stdout:
            return -1
        for line in stdout.decode("utf-8", "replace").splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "work":
                try:
                    return int(parts[1])
                except ValueError:
                    return -1
        return -1

    def _tmux_work_attached(self, c: Container) -> int:
        """Clients attached to the tmux `work` session; 0 if none/unreadable.

        Same probe shape as _tmux_work_activity but a different consumer:
        activity serves resolve()'s tie-break, this serves status_many's
        attached indicator. Kept separate so resolver and status semantics
        stay uncoupled.
        """
        if c.status != "running":
            return 0
        try:
            res = c.exec_run(
                ["tmux", "list-sessions", "-F",
                 "#{session_name} #{session_attached}"],
                demux=True,
            )
        except Exception:
            return 0
        if res.exit_code != 0:
            return 0
        stdout = res.output[0] if isinstance(res.output, tuple) else res.output
        if not stdout:
            return 0
        for line in stdout.decode("utf-8", "replace").splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "work":
                try:
                    return max(0, int(parts[1]))
                except ValueError:
                    return 0
        return 0

    def _uid(self, c: Container) -> str | None:
        return c.labels.get(self._settings.devpod_id_label)

    def _workspaces_owner(self, c: Container) -> str | None:
        """`user:group` owning the workspace, or None if unreadable.

        Read host-side from the bind mount's Source rather than by exec'ing
        into the container, so the socket proxy never needs EXEC for this.
        root:root means the devcontainer's setup-user step never ran — the
        container was created and abandoned before provisioning. That is what
        distinguishes a dud sibling from the real one, and uid 0 is root in
        both namespaces, so the discriminator survives the move. Non-root
        names now resolve against the HOST passwd database.
        """
        if c.status != "running":
            return None
        mount = _workspace_mount(
            c.attrs.get("Mounts", []), self._settings.workspace_mount_prefix
        )
        source = mount.get("Source") if mount else None
        if not source:
            return None
        try:
            st = os.stat(source)
        except OSError:
            return None
        try:
            user = pwd.getpwuid(st.st_uid).pw_name
        except KeyError:
            user = str(st.st_uid)
        try:
            group = grp.getgrgid(st.st_gid).gr_name
        except KeyError:
            group = str(st.st_gid)
        return f"{user}:{group}"

    def _image_digest(self, c: Container) -> str | None:
        # Config.Image is the ref the container was created from; for the
        # devbox (image-only devcontainer) that is the digest-pinned ref, e.g.
        # "repo@sha256:...". But a container created straight from an image
        # ID (no ref) also stores a bare "sha256:<hex>" there, which is the
        # image's own id, not a manifest digest, and would never match the
        # blueprint's digest again: a permanent false "outdated". Only trust
        # Config.Image when it carries a real pinned ref ("@sha256:...");
        # otherwise fall through to the guarded RepoDigests lookup below.
        image_ref = c.attrs.get("Config", {}).get("Image") or ""
        d = _sha256_of(image_ref) if "@sha256:" in image_ref else None
        if d:
            return d
        # Fallback needs /images, which the deployed socket proxy BLOCKS;
        # degrade to unknown rather than erroring the whole status call.
        try:
            repo_digests = (c.image.attrs.get("RepoDigests") or []) if c.image else []
        except Exception:
            return None
        return _sha256_of(repo_digests[0]) if repo_digests else None

    def siblings(self, ws_id: str) -> list[SiblingContainer]:
        """Per-container detail for every RUNNING candidate of a workspace.

        Deliberately NOT part of status_many: this execs into each container
        twice, which is far too expensive for the bulk hot path. Callers should
        only ask for workspaces that status_many already flagged with
        running_siblings > 1.
        """
        out = []
        for c in self._candidates(ws_id):
            out.append(
                SiblingContainer(
                    container_id=c.id,
                    container_name=c.name,
                    created=c.attrs.get("Created"),
                    state=c.status,
                    tmux_work_activity=self._tmux_work_activity(c),
                    workspaces_owner=self._workspaces_owner(c),
                )
            )
        return out

    def _liveness(self, c: Container | None) -> str:
        if c is None:
            return "absent"
        if c.status != "running":
            return "stopped"
        # Running: distinguish alive vs stale (bind-mount source gone).
        mount = _workspace_mount(
            c.attrs.get("Mounts", []), self._settings.workspace_mount_prefix
        )
        src = mount.get("Source") if mount else None
        if src and not os.path.isdir(src):
            return "stale"
        pid = (c.attrs.get("State") or {}).get("Pid")
        if pid:
            try:
                cwd = os.readlink(f"/proc/{pid}/cwd")
                if "(deleted)" in cwd:
                    return "stale"
            except OSError:
                pass  # /proc not readable from here; source check above stands
        return "alive"

    # ---- resolver (hot path) ---------------------------------------------

    def _resolve_candidates(
        self, ws_id: str, cands: list[Container],
        *, probe_single_activity: bool = True,
    ) -> CanonicalContainer:
        """Apply the one canonical-container policy to an existing candidate list.

        Window collection already has all containers in hand, so sharing the
        decision itself avoids a second Docker listing while ensuring attach
        and display can never choose different siblings.

        probe_single_activity=False skips the tmux exec on the (common)
        single-candidate path for callers that only need the canonical
        container id and discard tmux_work_activity (windows_many,
        status_many). The choice of container is identical either way; the
        sibling tie-break below always probes because activity IS the
        decision there.
        """
        if not cands:
            return CanonicalContainer(workspace_id=ws_id, container_id=None)

        if len(cands) == 1:
            # Single (running) candidate is chosen unconditionally, even with
            # no tmux session — matches legacy.
            c = cands[0]
            return CanonicalContainer(
                workspace_id=ws_id,
                container_id=c.id,
                container_name=c.name,
                devpod_uid=self._uid(c),
                state=c.status,
                tmux_work_activity=(
                    self._tmux_work_activity(c) if probe_single_activity
                    else -1
                ),
            )

        # >= 2 candidates: the sibling case. Tie-break by tmux `work` activity.
        scored = [(self._tmux_work_activity(c), c.attrs.get("Created", ""), c)
                  for c in cands]
        with_tmux = [t for t in scored if t[0] != -1]

        if not with_tmux:
            # Pathological: multiple containers for one workspace, none with a
            # live `work` session. Legacy REFUSES to guess (status 1); we
            # signal ambiguity and pick nothing rather than route into the
            # wrong sibling.
            return CanonicalContainer(
                workspace_id=ws_id,
                container_id=None,
                ambiguous=True,
                resolved_by="ambiguous-no-tmux",
                sibling_ids=[c.id for _, _, c in scored],
            )

        # Highest activity wins; newest `Created` only as a deterministic
        # breaker WITHIN the with-tmux set (never promotes a no-tmux sibling).
        with_tmux.sort(key=lambda t: (t[0], t[1]), reverse=True)
        activity, _, winner = with_tmux[0]
        siblings = [c.id for _, _, c in scored if c.id != winner.id]
        return CanonicalContainer(
            workspace_id=ws_id,
            container_id=winner.id,
            container_name=winner.name,
            devpod_uid=self._uid(winner),
            state=winner.status,
            tmux_work_activity=activity,
            sibling_ids=siblings,
        )

    def resolve(self, ws_id: str) -> CanonicalContainer:
        return self._resolve_candidates(ws_id, self._candidates(ws_id))

    # ---- deep inspect -----------------------------------------------------

    def inspect(
        self, ws_id: str, blueprint_image: str | None = None
    ) -> ContainerInspect:
        resolved = self.resolve(ws_id)
        if resolved.container_id is None:
            return ContainerInspect(
                workspace_id=ws_id,
                liveness="absent",
                blueprint_image=blueprint_image,
                image_current=image_current(None, blueprint_image),
            )
        c = self._client.containers.get(resolved.container_id)
        c.reload()
        a = c.attrs
        state = a.get("State", {})
        mounts = a.get("Mounts", [])
        ws_mount = _workspace_mount(mounts, self._settings.workspace_mount_prefix)
        source = ws_mount.get("Source") if ws_mount else None

        info = ContainerInspect(
            workspace_id=ws_id,
            container_id=c.id,
            container_name=c.name,
            devpod_uid=self._uid(c),
            devpod_user=c.labels.get("devpod.user"),
            status=state.get("Status"),
            running=bool(state.get("Running")),
            exit_code=state.get("ExitCode"),
            health=(state.get("Health") or {}).get("Status"),
            created=a.get("Created"),
            started_at=state.get("StartedAt"),
            image=(c.image.tags or [a.get("Image")])[0] if c.image else a.get("Image"),
            restart_count=a.get("RestartCount", 0),
            workspace_source=source,
            bind_mounts=[
                BindMount(
                    source=m.get("Source", ""),
                    destination=m.get("Destination", ""),
                    rw=m.get("RW", True),
                )
                for m in mounts
                if m.get("Type") == "bind"
            ],
            liveness=self._liveness(c),
        )
        digest = self._image_digest(c)
        info.image_digest = digest
        info.blueprint_image = blueprint_image
        info.image_current = image_current(digest, blueprint_image)
        if info.running:
            cpu, mem, mem_limit, mem_pct = self._cpu_mem(c)
            info.cpu_pct, info.mem_bytes = cpu, mem
            info.mem_limit, info.mem_pct = mem_limit, mem_pct
        if source:
            info.disk_bytes = self._disk_usage(source)
        return info

    def _cpu_mem(self, c: Container):
        try:
            s = c.stats(stream=False)
        except Exception:
            return None, None, None, None
        try:
            cpu, pre = s["cpu_stats"], s["precpu_stats"]
            cpu_delta = (
                cpu["cpu_usage"]["total_usage"] - pre["cpu_usage"]["total_usage"]
            )
            sys_delta = cpu.get("system_cpu_usage", 0) - pre.get("system_cpu_usage", 0)
            ncpu = cpu.get("online_cpus") or len(
                cpu["cpu_usage"].get("percpu_usage") or [1]
            )
            cpu_pct = (cpu_delta / sys_delta) * ncpu * 100.0 if sys_delta > 0 else 0.0
            mem = s["memory_stats"]
            usage = mem.get("usage", 0) - mem.get("stats", {}).get("inactive_file", 0)
            limit = mem.get("limit", 0)
            mem_pct = round(usage / limit * 100, 1) if limit else 0.0
            return round(cpu_pct, 1), usage, limit, mem_pct
        except (KeyError, ZeroDivisionError, TypeError):
            return None, None, None, None

    def _disk_usage(self, source: str) -> int | None:
        """Host-side `du -sb` on the bind-mount source. Cheap, no daemon call."""
        try:
            out = subprocess.run(
                ["du", "-sb", source],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if out.returncode == 0:
                return int(out.stdout.split()[0])
        except (subprocess.SubprocessError, ValueError, IndexError):
            pass
        return None

    # ---- bulk status (replaces _dvw_load_probe) --------------------------

    def _attached_many(self, containers: list[Container]) -> dict[str, int]:
        """Best-effort attached counts within one bounded response budget.

        A shared semaphore bounds probes across overlapping/repeated requests.
        There is deliberately no work queue: when all slots are occupied by
        slow Docker calls, later probes immediately retain the API's safe
        compatibility default 0 instead of building an unbounded backlog.
        """
        deadline = time.monotonic() + self._attached_probe_budget
        attached: dict[str, int] = {}
        result_lock = threading.Lock()
        workers: list[threading.Thread] = []

        def probe(c: Container) -> None:
            try:
                count = self._tmux_work_attached(c)
                with result_lock:
                    attached[c.id] = count
            except Exception:
                # _tmux_work_attached itself is fail-open, but keep the bulk
                # endpoint robust if a future implementation raises.
                return
            finally:
                self._attached_slots.release()

        for c in containers:
            if not self._attached_slots.acquire(blocking=False):
                continue
            worker = threading.Thread(
                target=probe,
                args=(c,),
                name="dvw-attached",
                daemon=True,
            )
            try:
                worker.start()
            except Exception:
                self._attached_slots.release()
                continue
            workers.append(worker)

        for worker in workers:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            worker.join(remaining)
        with result_lock:
            return dict(attached)

    def status_many(
        self, ids: list[str], blueprint_image: str | None = None
    ) -> list[WorkspaceStatus]:
        # Group containers per destination in one pass over devpod
        # containers, then answer each id locally. Running containers keep
        # the full group so duplicates can be resolved canonically below;
        # stopped ones only need a representative for liveness.
        running_by_dest: dict[str, list[Container]] = {}
        stopped_by_dest: dict[str, Container] = {}
        prefix = self._settings.workspace_mount_prefix
        for c in self._devpod_containers():
            wid = _ws_id_from_mounts(c.attrs.get("Mounts", []), prefix)
            if wid is None:
                continue
            if c.status == "running":
                running_by_dest.setdefault(wid, []).append(c)
            else:
                stopped_by_dest.setdefault(wid, c)

        # Pick each workspace's container with the same canonical policy as
        # attach/windows, so container_id/attached can never come from the
        # wrong sibling. The tie-break execs only run for actual duplicates;
        # the common single-candidate case stays exec-free.
        selected: dict[str, Container] = {}
        for ws_id in dict.fromkeys(ids):
            running = running_by_dest.get(ws_id, [])
            if len(running) == 1:
                selected[ws_id] = running[0]
            elif running:
                resolved = self._resolve_candidates(
                    ws_id, running, probe_single_activity=False
                )
                canonical = next(
                    (c for c in running if c.id == resolved.container_id),
                    None,
                )
                # ambiguous-no-tmux: the resolver refuses to pick, but every
                # sibling reports the same liveness here and running_siblings
                # already flags the duplication — keep the first listed.
                selected[ws_id] = canonical if canonical else running[0]
            elif ws_id in stopped_by_dest:
                selected[ws_id] = stopped_by_dest[ws_id]

        selected_running = {
            c.id: c for c in selected.values() if c.status == "running"
        }
        attached = self._attached_many(list(selected_running.values()))

        out = []
        for ws_id in ids:
            c = selected.get(ws_id)
            digest = self._image_digest(c) if c else None
            out.append(
                WorkspaceStatus(
                    id=ws_id,
                    liveness=self._liveness(c),
                    container_id=c.id if c else None,
                    devpod_uid=self._uid(c) if c else None,
                    running_siblings=len(running_by_dest.get(ws_id, [])),
                    attached=attached.get(c.id, 0) if c else 0,
                    image_digest=digest,
                    blueprint_image=blueprint_image,
                    image_current=image_current(digest, blueprint_image),
                )
            )
        return out

    # ---- orphans ----------------------------------------------------------

    def orphans(self, catalog_ids: set[str]) -> list[Orphan]:
        prefix = self._settings.workspace_mount_prefix
        out = []
        for c in self._devpod_containers():
            mounts = c.attrs.get("Mounts", [])
            wid = _ws_id_from_mounts(mounts, prefix)
            if wid is not None and wid in catalog_ids:
                continue
            ws_mount = _workspace_mount(mounts, prefix)
            source = ws_mount.get("Source") if ws_mount else None
            if ws_mount is None:
                mount_status = "nomount"
            elif source and os.path.isdir(source):
                mount_status = "alive"
            else:
                mount_status = "deleted"
            out.append(
                Orphan(
                    container_id=c.id,
                    container_name=c.name,
                    devpod_uid=self._uid(c),
                    workspace_id=wid,
                    state=c.status,
                    mount_status=mount_status,
                    mount_source=source,
                )
            )
        return out

    # ---- waiting windows ---------------------------------------------------

    def waiting_windows(self) -> list[WaitingWindow]:
        """All @waiting-flagged windows, newest first. Since the tree-view
        work this is a projection of the same snapshot that serves
        /containers/windows — one exec per container, not two."""
        out: list[WaitingWindow] = []
        for ww in self.windows_many():
            for w in ww.windows:
                if w.waiting_since is None:
                    continue
                out.append(WaitingWindow(
                    workspace_id=ww.workspace_id,
                    container_id=ww.container_id,
                    window_id=w.window_id,
                    window_name=w.name,
                    waiting_since=w.waiting_since,
                ))
        out.sort(key=lambda w: w.waiting_since, reverse=True)
        return out

    # ---- window snapshot (tree view) ---------------------------------------

    def _work_session_windows(self, c: Container) -> tuple[int, list[WindowInfo]]:
        """One exec: every window of `work` + the session's attached count.
        (0, []) on any failure — a broken tmux must not 500 an endpoint."""
        if c.status != "running":
            return 0, []
        try:
            res = c.exec_run(
                ["tmux", "list-windows", "-t", "work", "-F",
                 "#{window_id}\t#{window_name}\t#{window_active}"
                 "\t#{window_activity}\t#{@waiting}\t#{pane_current_command}"
                 "\t#{session_attached}"],
                demux=True,
            )
        except Exception:
            return 0, []
        if res.exit_code != 0:
            return 0, []
        stdout = res.output[0] if isinstance(res.output, tuple) else res.output
        if not stdout:
            return 0, []
        attached = 0
        windows: list[WindowInfo] = []
        for line in stdout.decode("utf-8", "replace").splitlines():
            parts = line.split("\t")
            if len(parts) != 7 or not parts[0].startswith("@"):
                continue
            win_id, name, active, activity, waiting, command, sess_att = parts
            try:
                attached = max(attached, max(0, int(sess_att)))
            except ValueError:
                pass

            def _int(v: str, default: int) -> int:
                try:
                    return int(v)
                except ValueError:
                    return default

            waiting_since = _int(waiting, -1) if waiting else -1
            windows.append(WindowInfo(
                window_id=win_id,
                name=name,
                active=active == "1",
                activity=_int(activity, -1),
                waiting_since=waiting_since if waiting_since >= 0 else None,
                command=command,
            ))
        return attached, windows

    def windows_many(self) -> list[WorkspaceWindows]:
        """Window snapshots from the same canonical containers attach uses.

        A workspace with multiple running siblings and no live tmux session is
        deliberately omitted: resolve() refuses to guess in that case, so
        exposing either sibling's window ids would make display and attach
        disagree.
        """
        out: list[WorkspaceWindows] = []
        prefix = self._settings.workspace_mount_prefix
        by_workspace: dict[str, list[Container]] = {}
        for c in self._devpod_containers():
            if c.status != "running":
                continue
            ws_id = _ws_id_from_mounts(c.attrs.get("Mounts", []), prefix)
            if ws_id is None:
                continue
            by_workspace.setdefault(ws_id, []).append(c)

        for ws_id, candidates in by_workspace.items():
            # probe_single_activity=False: only the container id is used
            # here, so the common single-candidate case must stay at one
            # exec per container (the window snapshot itself), not two.
            resolved = self._resolve_candidates(
                ws_id, candidates, probe_single_activity=False
            )
            if resolved.container_id is None:
                continue
            canonical = next(
                c for c in candidates if c.id == resolved.container_id
            )
            attached, windows = self._work_session_windows(canonical)
            out.append(WorkspaceWindows(
                workspace_id=ws_id, container_id=canonical.id,
                attached=attached, windows=windows))
        return out
