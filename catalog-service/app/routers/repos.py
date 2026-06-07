from __future__ import annotations

from fastapi import APIRouter, HTTPException

from ..deps import StoreDep
from ..models import Repo, RepoUpsert
from ..store import NotFoundError

router = APIRouter(prefix="/repos", tags=["repos"])


@router.get("", response_model=list[Repo])
async def list_repos(store: StoreDep) -> list[Repo]:
    """Repos in MRU order."""
    return store.list_repos()


@router.get("/by-url", response_model=Repo)
async def get_repo(url: str, store: StoreDep) -> Repo:
    """Look up a repo by its URL (query param, since URLs aren't path-safe)."""
    try:
        return store.get_repo(url)
    except NotFoundError:
        raise HTTPException(404, f"repo not found: {url}")


@router.post("", response_model=Repo)
async def upsert_repo(body: RepoUpsert, store: StoreDep) -> Repo:
    return await store.upsert_repo(body.url, body.last_branch)
