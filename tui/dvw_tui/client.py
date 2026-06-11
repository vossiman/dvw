"""Async read-only client for the dvw catalog service over a unix socket.

The bash launcher guarantees the socket (DVW_TUI_SOCKET) before the TUI
starts; on the box it's the service socket, remotely it's an ssh -L forward.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import httpx


class CatalogError(Exception):
    """Catalog unreachable or returned an error response."""


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

    async def statuses(self) -> dict[str, str]:
        return {d["id"]: d["liveness"]
                for d in await self._get("/containers/status")}

    async def workspaces_with_status(self) -> list[Workspace]:
        ws = await self.workspaces()
        liveness = await self.statuses()
        for w in ws:
            w.liveness = liveness.get(w.id, "unknown")
        return ws

    async def inspect(self, workspace_id: str) -> dict:
        return await self._get(f"/workspaces/{workspace_id}/inspect")

    async def orphans(self) -> list[dict]:
        return await self._get("/containers/orphans")

    async def health(self) -> dict:
        return await self._get("/health")

    async def aclose(self) -> None:
        await self._client.aclose()
