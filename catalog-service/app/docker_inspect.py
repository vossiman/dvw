"""Local Docker inspection — the whole reason the service lives on vossisrv.

Everything dvw used to do over SSH (enumerate containers, match the
/workspaces/<id> bind mount, tie-break siblings by tmux activity, detect
orphans and stale bind mounts) happens here against the local Docker socket,
authoritatively and in milliseconds.

docker-py is synchronous/blocking; callers run these methods in a threadpool
(see app/deps.py) so the event loop is never stalled.
"""

from __future__ import annotations

import os
import subprocess
from typing import Protocol

import docker
from docker.models.containers import Container

from .config import Settings
from .models import (
    BindMount,
    CanonicalContainer,
    ContainerInspect,
    Orphan,
    WorkspaceStatus,
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


class Inspector(Protocol):
    def ping(self) -> bool: ...
    def resolve(self, ws_id: str) -> CanonicalContainer: ...
    def inspect(self, ws_id: str) -> ContainerInspect: ...
    def status_many(self, ids: list[str]) -> list[WorkspaceStatus]: ...
    def orphans(self, catalog_ids: set[str]) -> list[Orphan]: ...


class DockerInspector:
    def __init__(self, settings: Settings):
        self._settings = settings
        if settings.docker_host:
            self._client = docker.DockerClient(
                base_url=settings.docker_host, timeout=settings.docker_timeout
            )
        else:
            self._client = docker.from_env(timeout=settings.docker_timeout)

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

    def _uid(self, c: Container) -> str | None:
        return c.labels.get(self._settings.devpod_id_label)

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

    def resolve(self, ws_id: str) -> CanonicalContainer:
        cands = self._candidates(ws_id)
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
                tmux_work_activity=self._tmux_work_activity(c),
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

    # ---- deep inspect -----------------------------------------------------

    def inspect(self, ws_id: str) -> ContainerInspect:
        resolved = self.resolve(ws_id)
        if resolved.container_id is None:
            return ContainerInspect(workspace_id=ws_id, liveness="absent")
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

    def status_many(self, ids: list[str]) -> list[WorkspaceStatus]:
        # Build a destination -> container map in one pass over devpod
        # containers, then answer each id locally.
        by_dest: dict[str, Container] = {}
        prefix = self._settings.workspace_mount_prefix
        for c in self._devpod_containers():
            wid = _ws_id_from_mounts(c.attrs.get("Mounts", []), prefix)
            if wid is None:
                continue
            # Prefer a running container if duplicates share a destination.
            existing = by_dest.get(wid)
            if existing is None or (
                existing.status != "running" and c.status == "running"
            ):
                by_dest[wid] = c

        out = []
        for ws_id in ids:
            c = by_dest.get(ws_id)
            out.append(
                WorkspaceStatus(
                    id=ws_id,
                    liveness=self._liveness(c),
                    container_id=c.id if c else None,
                    devpod_uid=self._uid(c) if c else None,
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
