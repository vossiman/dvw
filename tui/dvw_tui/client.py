"""Async read-only client for the dvw catalog service over a unix socket.

The bash launcher guarantees the socket (DVW_TUI_SOCKET) before the TUI
starts; on the box it's the service socket, remotely it's an ssh -L forward.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

import httpx


class CatalogError(Exception):
    """Catalog unreachable or returned an error response."""


@dataclass
class WindowInfo:
    """A single tmux window in a container's snapshot from
    `GET /v1/containers/windows`."""

    window_id: str
    name: str
    active: bool = False
    activity: int = -1
    waiting_since: int | None = None
    command: str = ""


@dataclass
class WorkspaceWindows:
    """A workspace's window snapshot. Deliberately omits container_id —
    the TUI never uses it."""

    workspace_id: str
    attached: int = 0
    windows: list[WindowInfo] = field(default_factory=list)


@dataclass
class Workspace:
    id: str
    repo: str
    branch: str
    ide: str
    provider: str
    last_used_at: str | None = None
    created_on: str | None = None
    liveness: str = "unknown"  # merged in from /containers/status
    attached: int = 0  # merged in from /containers/status

    @property
    def short_repo(self) -> str:
        r = self.repo
        for prefix in ("git@github.com:", "https://github.com/"):
            r = r.removeprefix(prefix)
        return r.removesuffix(".git")

    @classmethod
    def from_api(cls, d: dict) -> "Workspace":
        return cls(
            id=d["id"],
            repo=d.get("repo", ""),
            branch=d.get("branch", ""),
            ide=d.get("ide", "none"),
            provider=d.get("provider", ""),
            last_used_at=d.get("last_used_at"),
            created_on=d.get("created_on"),
        )


class CatalogClient:
    def __init__(
        self,
        socket_path: str | None = None,
        token: str | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        socket_path = socket_path or os.environ.get("DVW_TUI_SOCKET", "")
        if token is None:
            token = os.environ.get("DVW_CATALOG_TOKEN") or None
        headers = {"authorization": f"Bearer {token}"} if token else {}
        self._client = httpx.AsyncClient(
            transport=transport or httpx.AsyncHTTPTransport(uds=socket_path),
            base_url="http://dvw/v1",
            headers=headers,
            timeout=10.0,
        )

    async def _get(self, path: str) -> object:
        try:
            resp = await self._client.get(path)
            resp.raise_for_status()
            return resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise CatalogError(str(exc)) from exc

    async def workspaces(self) -> list[Workspace]:
        return [Workspace.from_api(d) for d in await self._get("/workspaces")]

    async def statuses(self) -> dict[str, dict]:
        return {d["id"]: d for d in await self._get("/containers/status")}

    async def workspaces_with_status(self) -> list[Workspace]:
        ws = await self.workspaces()
        statuses = await self.statuses()
        for w in ws:
            s = statuses.get(w.id, {})
            w.liveness = s.get("liveness", "unknown")
            try:
                w.attached = max(0, int(s.get("attached", 0) or 0))
            except (TypeError, ValueError):
                w.attached = 0
        return ws

    async def inspect(self, workspace_id: str) -> dict:
        return await self._get(f"/workspaces/{workspace_id}/inspect")

    async def orphans(self) -> list[dict]:
        return await self._get("/containers/orphans")

    async def repos(self) -> list[str]:
        return [d["url"] for d in await self._get("/repos")]

    async def windows(self) -> dict[str, WorkspaceWindows]:
        """Per-workspace tmux window snapshots. Fail-open: any catalog
        error, HTTP error, or malformed body yields {} — the old-server
        case where the TUI simply has no window info to render. Malformed
        entries and windows are skipped individually."""
        try:
            body = await self._get("/containers/windows")
        except CatalogError:
            return {}
        if not isinstance(body, list):
            return {}
        out: dict[str, WorkspaceWindows] = {}
        duplicate_ids: set[str] = set()
        for entry in body:
            if not isinstance(entry, dict):
                continue
            try:
                workspace_id = entry["workspace_id"]
            except (KeyError, TypeError):
                continue
            # Servers predating canonical window collection can emit one
            # entry per sibling. Never let response order choose window ids
            # that attach will route to a different container.
            if workspace_id in duplicate_ids:
                continue
            if workspace_id in out:
                out.pop(workspace_id)
                duplicate_ids.add(workspace_id)
                continue
            windows: list[WindowInfo] = []
            for w in entry.get("windows") or []:
                if not isinstance(w, dict):
                    continue
                try:
                    windows.append(WindowInfo(
                        window_id=w["window_id"],
                        name=w["name"],
                        active=bool(w.get("active", False)),
                        activity=int(w.get("activity", -1)),
                        waiting_since=(
                            None if w.get("waiting_since") is None
                            else int(w["waiting_since"])
                        ),
                        command=w.get("command", ""),
                    ))
                except (KeyError, TypeError, ValueError):
                    continue
            try:
                attached = max(0, int(entry.get("attached", 0) or 0))
            except (TypeError, ValueError):
                attached = 0
            out[workspace_id] = WorkspaceWindows(
                workspace_id=workspace_id, attached=attached, windows=windows,
            )
        return out

    async def health(self) -> dict:
        return await self._get("/health")

    async def aclose(self) -> None:
        await self._client.aclose()
