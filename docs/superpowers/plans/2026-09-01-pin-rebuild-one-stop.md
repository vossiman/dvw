# pin-rebuild One-Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command (`dvw pin-rebuild <id>`) that PRs the stale image pin against the branch the rebuild actually builds from, verifies the merge, pulls the devpod source clone, rebuilds, and asserts the result, plus an outdated-image badge in the TUI and `dvw status`.

**Architecture:** The catalog service (runs on vossisrv as the account owning the devpod agent dir) gains read/pull endpoints for the source clone and a TTL-cached blueprint image ref that it compares against each container's image digest. The bash side gains `cmd_pin_rebuild` driving the whole loop with an assertion per step, and `_dvw_pin_state` learns to use the clone's live branch. The TUI renders the comparison and adds a menu entry.

**Tech Stack:** bash + bats (`tests/bats/run.sh`), FastAPI + pytest (`catalog-service/`, run with `cd catalog-service && uv run pytest`), Textual + pytest (`tui/`, run with `cd tui && uv run pytest ../tests`).

**Spec:** `docs/superpowers/specs/2026-09-01-pin-rebuild-one-stop-design.md`

## Global Constraints

- Never use em dashes in generated prose (commit messages, comments, docs). Recast the sentence.
- The deployed service reaches docker through a socket proxy that **blocks `/images`**; any `container.image` access must be wrapped in try/except and degrade to `None`.
- Image comparison is by `sha256:` component only; a tag-pinned blueprint yields `null`/unknown, never `false`.
- All GitHub/network access in bats tests is stubbed (no gh, no curl); follow `tests/bats/pin-sync.bats` conventions.
- Service tests never touch real git remotes: pull tests use a local bare repo as `origin`.
- New payload fields must be optional with defaults so old clients/servers interop (see the `running_siblings // ""` note in `lib/connect-resolver.sh`).

---

### Task 1: Service, source-clone reader (`app/source.py`)

**Files:**
- Create: `catalog-service/app/source.py`
- Modify: `catalog-service/app/config.py` (Settings: `devpod_agent_workspaces_dir`, `source_path()`)
- Modify: `catalog-service/app/models.py` (add `WorkspaceSource`)
- Test: `catalog-service/tests/test_source.py`

**Interfaces:**
- Produces: `WorkspaceSource` model; `read_source(ws_id: str, path: Path) -> WorkspaceSource`; `pull_source(ws_id: str, path: Path) -> WorkspaceSource` raising `SourcePullError(status: int, detail: str)`; `Settings.source_path(ws_id: str) -> Path`.

- [ ] **Step 1: Write the failing tests**

```python
# catalog-service/tests/test_source.py
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from app import source
from app.source import SourcePullError


def _git(path: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(path), *args], check=True,
                   capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                        "HOME": str(path), "PATH": "/usr/bin:/bin"})


PIN = "ghcr.io/vossiman/devbox-base@sha256:" + "a" * 64
NEW_PIN = "ghcr.io/vossiman/devbox-base@sha256:" + "b" * 64


@pytest.fixture
def clone(tmp_path):
    """origin (bare) + clone with a committed devcontainer pin."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
    work = tmp_path / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)
    dc = work / ".devcontainer"
    dc.mkdir()
    (dc / "devcontainer.json").write_text(
        '{\n  // devbox\n  "image": "%s"\n}\n' % PIN)
    _git(work, "add", "-A")
    _git(work, "commit", "-qm", "seed")
    _git(work, "push", "-q", "origin", "HEAD:refs/heads/main")
    clone = tmp_path / "content"
    subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True)
    return clone


def test_read_absent_clone(tmp_path):
    src = source.read_source("ws", tmp_path / "nope")
    assert src.present is False and src.branch is None


def test_read_clean_clone(clone):
    src = source.read_source("ws", clone)
    assert src.present and src.branch == "main" and not src.dirty
    assert not src.detached and src.head
    assert src.committed_pin == PIN          # JSONC comment tolerated


def test_read_dirty_and_detached(clone):
    (clone / "x").write_text("x")
    assert source.read_source("ws", clone).dirty is True
    (clone / "x").unlink()
    _git(clone, "checkout", "-q", "--detach")
    src = source.read_source("ws", clone)
    assert src.detached is True and src.branch is None


def test_pull_fast_forwards(clone, tmp_path):
    seed = tmp_path / "seed"
    f = seed / ".devcontainer" / "devcontainer.json"
    f.write_text(f.read_text().replace(PIN, NEW_PIN))
    _git(seed, "commit", "-aqm", "bump")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    src = source.pull_source("ws", clone)
    assert src.committed_pin == NEW_PIN


def test_pull_refuses_dirty(clone):
    (clone / "y").write_text("y")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 409


def test_pull_refuses_detached(clone):
    _git(clone, "checkout", "-q", "--detach")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 409


def test_pull_absent_404(tmp_path):
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", tmp_path / "gone")
    assert e.value.status == 404


def test_pull_surfaces_git_stderr(clone, tmp_path):
    # Diverge: local commit + different origin commit -> ff-only fails.
    (clone / "local").write_text("l")
    _git(clone, "add", "-A"); _git(clone, "commit", "-qm", "local")
    seed = tmp_path / "seed"
    (seed / "remote").write_text("r")
    _git(seed, "add", "-A"); _git(seed, "commit", "-qm", "remote")
    _git(seed, "push", "-q", "origin", "HEAD:refs/heads/main")
    with pytest.raises(SourcePullError) as e:
        source.pull_source("ws", clone)
    assert e.value.status == 502
```

- [ ] **Step 2: Run to verify failure**, `cd catalog-service && uv run pytest tests/test_source.py -q`. Expected: import error (`app.source` missing).

- [ ] **Step 3: Implement**

`app/models.py`, next to `ContainerInspect`:

```python
class WorkspaceSource(BaseModel):
    """The devpod source clone a workspace's rebuild actually builds from.

    `committed_pin` is read from the WORKING TREE, not GitHub: the working
    tree is what `devpod up --recreate` reads, so it is the only copy whose
    value predicts the rebuild's outcome.
    """

    workspace_id: str
    path: str
    present: bool = False
    branch: str | None = None
    head: str | None = None
    dirty: bool = False
    detached: bool = False
    remote: str | None = None
    committed_pin: str | None = None
```

`app/config.py`, inside `Settings`:

```python
    # devpod agent workspace dirs on this box; each workspace's build source
    # is <dir>/<id>/content. "~" is the service account (vossi on vossisrv).
    devpod_agent_workspaces_dir: Path = Path(
        "~/.devpod/agent/contexts/default/workspaces")
```

and a method:

```python
    def source_path(self, ws_id: str) -> Path:
        return (self.devpod_agent_workspaces_dir.expanduser()
                / ws_id / "content")
```

`app/source.py`:

```python
"""Read and fast-forward the devpod source clone a workspace builds from.

Blocking (subprocess git); callers hop through run_in_threadpool. Pull
authenticates with whatever git credentials the service account already
holds, the same ones devpod's own clone used.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from .models import WorkspaceSource

_IMAGE_RE = re.compile(r'"image"\s*:\s*"([^"]+)"')


class SourcePullError(Exception):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _git(path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(path), *args],
                          capture_output=True, text=True, timeout=60)


def _pin_from_devcontainer(path: Path) -> str | None:
    f = path / ".devcontainer" / "devcontainer.json"
    if not f.is_file():
        return None
    try:
        text = f.read_text()
    except OSError:
        return None
    try:
        image = json.loads(text).get("image")
        if isinstance(image, str):
            return image
    except ValueError:
        pass  # JSONC; fall through to the regex
    m = _IMAGE_RE.search(text)
    return m.group(1) if m else None


def read_source(ws_id: str, path: Path) -> WorkspaceSource:
    src = WorkspaceSource(workspace_id=ws_id, path=str(path))
    if not (path / ".git").exists():
        return src
    src.present = True
    r = _git(path, "rev-parse", "HEAD")
    if r.returncode == 0:
        src.head = r.stdout.strip() or None
    r = _git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
    if r.returncode == 0 and r.stdout.strip():
        src.branch = r.stdout.strip()
    else:
        src.detached = True
    r = _git(path, "status", "--porcelain")
    src.dirty = r.returncode == 0 and bool(r.stdout.strip())
    r = _git(path, "remote", "get-url", "origin")
    if r.returncode == 0:
        src.remote = r.stdout.strip() or None
    src.committed_pin = _pin_from_devcontainer(path)
    return src


def pull_source(ws_id: str, path: Path) -> WorkspaceSource:
    src = read_source(ws_id, path)
    if not src.present:
        raise SourcePullError(404, f"no source clone at {path}")
    if src.detached:
        raise SourcePullError(
            409, "source clone is on a detached HEAD; check out a branch first")
    if src.dirty:
        raise SourcePullError(
            409, "source clone has uncommitted changes; refusing to pull over them")
    r = _git(path, "pull", "--ff-only")
    if r.returncode != 0:
        raise SourcePullError(
            502, f"git pull --ff-only failed: {r.stderr.strip()[:500]}")
    return read_source(ws_id, path)
```

- [ ] **Step 4: Run to verify pass**, `uv run pytest tests/test_source.py -q`. Expected: all pass.
- [ ] **Step 5: Commit**, `git add catalog-service/app/source.py catalog-service/app/config.py catalog-service/app/models.py catalog-service/tests/test_source.py && git commit -m "feat(catalog): read and ff-pull the devpod source clone"`

---

### Task 2: Service, `/source` endpoints

**Files:**
- Modify: `catalog-service/app/routers/workspaces.py`
- Test: `catalog-service/tests/test_source_api.py`

**Interfaces:**
- Consumes: Task 1's `read_source` / `pull_source` / `SourcePullError` / `Settings.source_path`.
- Produces: `GET /v1/workspaces/{id}/source -> WorkspaceSource`; `POST /v1/workspaces/{id}/source/pull -> WorkspaceSource` (409/404/502 via `SourcePullError.status`).

- [ ] **Step 1: Write the failing tests**

```python
# catalog-service/tests/test_source_api.py
from __future__ import annotations

import subprocess


def _create(client, ws_id="proj"):
    return client.post("/v1/workspaces", json={
        "id": ws_id, "repo": "git@github.com:me/proj", "branch": "main"})


def _seed_clone(settings, ws_id="proj"):
    """A real git repo (with origin) at settings.source_path(ws_id)."""
    path = settings.source_path(ws_id)
    origin = path.parent / "origin.git"
    origin.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
    seed = path.parent / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True)
    (seed / "f").write_text("f")
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
           "PATH": "/usr/bin:/bin"}
    subprocess.run(["git", "-C", str(seed), "add", "-A"], check=True, env=env)
    subprocess.run(["git", "-C", str(seed), "commit", "-qm", "s"],
                   check=True, env=env)
    subprocess.run(["git", "-C", str(seed), "push", "-q", "origin",
                    "HEAD:refs/heads/main"], check=True)
    subprocess.run(["git", "clone", "-q", str(origin), str(path)], check=True)
    return path


def test_source_absent_clone_is_present_false(client):
    _create(client)
    r = client.get("/v1/workspaces/proj/source")
    assert r.status_code == 200
    assert r.json()["present"] is False


def test_source_unknown_workspace_404(client):
    assert client.get("/v1/workspaces/nope/source").status_code == 404


def test_source_reads_clone(client, settings):
    _create(client)
    _seed_clone(settings)
    body = client.get("/v1/workspaces/proj/source").json()
    assert body["present"] is True and body["branch"] == "main"


def test_pull_dirty_409(client, settings):
    _create(client)
    path = _seed_clone(settings)
    (path / "dirt").write_text("d")
    r = client.post("/v1/workspaces/proj/source/pull")
    assert r.status_code == 409
    assert "uncommitted" in r.text


def test_pull_ok(client, settings):
    _create(client)
    _seed_clone(settings)
    r = client.post("/v1/workspaces/proj/source/pull")
    assert r.status_code == 200 and r.json()["present"] is True
```

The `settings` fixture must be the SAME instance the app uses. Check `tests/conftest.py`: the `client` fixture already builds the app from the `settings` fixture via dependency overrides; if `devpod_agent_workspaces_dir` is not part of it, extend the `settings` fixture with `devpod_agent_workspaces_dir=tmp_path / "agent"` so `source_path()` lands under tmp_path.

- [ ] **Step 2: Run to verify failure**, `uv run pytest tests/test_source_api.py -q`. Expected: 404s (route missing).

- [ ] **Step 3: Implement**, in `app/routers/workspaces.py`:

```python
from starlette.concurrency import run_in_threadpool

from .. import source as source_mod
from ..deps import SettingsDep
from ..models import WorkspaceSource
from ..source import SourcePullError


@router.get("/{ws_id}/source", response_model=WorkspaceSource)
async def workspace_source(
    ws_id: WsId, store: StoreDep, settings: SettingsDep
) -> WorkspaceSource:
    await _get_or_404(store, ws_id)
    return await run_in_threadpool(
        source_mod.read_source, ws_id, settings.source_path(ws_id))


@router.post("/{ws_id}/source/pull", response_model=WorkspaceSource)
async def workspace_source_pull(
    ws_id: WsId, store: StoreDep, settings: SettingsDep
) -> WorkspaceSource:
    await _get_or_404(store, ws_id)
    try:
        return await run_in_threadpool(
            source_mod.pull_source, ws_id, settings.source_path(ws_id))
    except SourcePullError as exc:
        raise HTTPException(status_code=exc.status, detail=exc.detail)
```

Match the file's existing import style; `HTTPException`, `WsId`, `StoreDep`, `_get_or_404` already exist there. If `SettingsDep` is not already imported in this router, import it from `..deps`.

- [ ] **Step 4: Run to verify pass**, `uv run pytest tests/test_source_api.py tests/test_workspaces.py -q`.
- [ ] **Step 5: Commit**, `git commit -am "feat(catalog): GET/POST workspace source endpoints"`

---

### Task 3: Service, blueprint image cache

**Files:**
- Create: `catalog-service/app/blueprint_image.py`
- Modify: `catalog-service/app/config.py` (two settings), `catalog-service/app/main.py` (lifespan wiring), `catalog-service/app/deps.py` (provider)
- Test: `catalog-service/tests/test_blueprint_image.py`

**Interfaces:**
- Produces: `BlueprintImageCache(url: str, ttl: float)` with blocking `.get() -> str | None`; deps `get_blueprint_image_cache(request) -> BlueprintImageCache` and `BlueprintImageDep`. App state key: `app.state.blueprint_image`.

- [ ] **Step 1: Write the failing tests**

```python
# catalog-service/tests/test_blueprint_image.py
from __future__ import annotations

from app.blueprint_image import BlueprintImageCache

PIN = "ghcr.io/x/y@sha256:" + "c" * 64


def _cache(monkeypatch, results, ttl=900.0):
    """results: list of str payloads or Exceptions, consumed per fetch."""
    cache = BlueprintImageCache("https://example.invalid/devcontainer.json", ttl)
    calls = {"n": 0}

    def fake_fetch(url, timeout):
        r = results[min(calls["n"], len(results) - 1)]
        calls["n"] += 1
        if isinstance(r, Exception):
            raise r
        return r
    monkeypatch.setattr("app.blueprint_image._fetch", fake_fetch)
    return cache, calls


def test_parses_image(monkeypatch):
    cache, _ = _cache(monkeypatch, ['{"image": "%s"}' % PIN])
    assert cache.get() == PIN


def test_caches_within_ttl(monkeypatch):
    cache, calls = _cache(monkeypatch, ['{"image": "%s"}' % PIN])
    cache.get(); cache.get()
    assert calls["n"] == 1


def test_refetches_after_ttl(monkeypatch):
    cache, calls = _cache(monkeypatch, ['{"image": "%s"}' % PIN], ttl=0.0)
    cache.get(); cache.get()
    assert calls["n"] == 2


def test_serves_stale_on_fetch_failure(monkeypatch):
    cache, _ = _cache(
        monkeypatch, ['{"image": "%s"}' % PIN, OSError("down")], ttl=0.0)
    assert cache.get() == PIN
    assert cache.get() == PIN          # second fetch fails, stale served


def test_none_when_never_fetched(monkeypatch):
    cache, _ = _cache(monkeypatch, [OSError("down")])
    assert cache.get() is None


def test_jsonc_fallback(monkeypatch):
    cache, _ = _cache(
        monkeypatch, ['{ // hi\n "image": "%s" }' % PIN], ttl=0.0)
    assert cache.get() == PIN
```

- [ ] **Step 2: Run to verify failure**, `uv run pytest tests/test_blueprint_image.py -q`. Expected: import error.

- [ ] **Step 3: Implement**

`app/blueprint_image.py`:

```python
"""TTL-cached blueprint image ref, fetched from the aicoding blueprint's
devcontainer.json. One fetch serves every client and every status row; a
fetch failure serves the last good value, or None when there is none.
stdlib urllib on purpose: no runtime dependency for one GET."""

from __future__ import annotations

import json
import re
import threading
import time
import urllib.request

_IMAGE_RE = re.compile(r'"image"\s*:\s*"([^"]+)"')


def _fetch(url: str, timeout: float) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310
        return resp.read().decode("utf-8", "replace")


def _parse_image(text: str) -> str | None:
    try:
        image = json.loads(text).get("image")
        if isinstance(image, str):
            return image
    except ValueError:
        pass
    m = _IMAGE_RE.search(text)
    return m.group(1) if m else None


class BlueprintImageCache:
    def __init__(self, url: str, ttl: float) -> None:
        self._url = url
        self._ttl = ttl
        self._lock = threading.Lock()
        self._value: str | None = None
        self._fetched_at: float | None = None

    def get(self) -> str | None:
        """Blocking; call via run_in_threadpool from async code."""
        with self._lock:
            now = time.monotonic()
            fresh = (self._fetched_at is not None
                     and now - self._fetched_at < self._ttl)
            if fresh:
                return self._value
            try:
                image = _parse_image(_fetch(self._url, timeout=10))
            except Exception:
                return self._value          # stale beats nothing
            if image is not None:
                self._value = image
                self._fetched_at = now
            return self._value
```

`app/config.py` Settings additions:

```python
    # The aicoding blueprint devcontainer.json (owns the current image pin).
    blueprint_devcontainer_url: str = (
        "https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup"
        "/main/devcontainer.json")
    # Blueprint image cache TTL, seconds.
    blueprint_image_ttl: float = 900.0
```

`app/main.py`: where `app.state.blueprint_store` is set in the lifespan, add:

```python
    app.state.blueprint_image = BlueprintImageCache(
        settings.blueprint_devcontainer_url, settings.blueprint_image_ttl)
```

`app/deps.py`:

```python
from .blueprint_image import BlueprintImageCache


def get_blueprint_image_cache(request: Request) -> BlueprintImageCache:
    return request.app.state.blueprint_image


BlueprintImageDep = Annotated[
    BlueprintImageCache, Depends(get_blueprint_image_cache)]
```

- [ ] **Step 4: Run to verify pass**, `uv run pytest tests/test_blueprint_image.py -q`, then the whole suite `uv run pytest -q` (lifespan change must not break app startup in tests).
- [ ] **Step 5: Commit**, `git commit -am "feat(catalog): TTL-cached blueprint image ref"`

---

### Task 4: Service, image digest comparison in status and inspect

**Files:**
- Modify: `catalog-service/app/models.py` (`WorkspaceStatus`, `ContainerInspect`: 3 new fields each)
- Modify: `catalog-service/app/docker_inspect.py` (digest extraction; `status_many` / `inspect` signatures)
- Modify: `catalog-service/app/routers/containers.py`, `catalog-service/app/routers/workspaces.py` (pass the blueprint ref)
- Modify: `catalog-service/tests/conftest.py` (`FakeInspector` signatures)
- Test: `catalog-service/tests/test_image_current.py`

**Interfaces:**
- Consumes: Task 3's `BlueprintImageDep` + `.get()`.
- Produces: on both payloads: `image_digest: str | None`, `blueprint_image: str | None`, `image_current: bool | None`. New signatures: `Inspector.status_many(ids, blueprint_image=None)`, `Inspector.inspect(ws_id, blueprint_image=None)`. Helper `image_current(digest, blueprint_ref) -> bool | None` in `docker_inspect.py`.

- [ ] **Step 1: Write the failing tests**

```python
# catalog-service/tests/test_image_current.py
from __future__ import annotations

from app.docker_inspect import _sha256_of, image_current

BP = "ghcr.io/x/y@sha256:" + "a" * 64
DIGEST_A = "sha256:" + "a" * 64
DIGEST_B = "sha256:" + "b" * 64


def test_sha256_of():
    assert _sha256_of(BP) == DIGEST_A
    assert _sha256_of("ghcr.io/x/y:latest") is None
    assert _sha256_of(None) is None


def test_image_current_tristate():
    assert image_current(DIGEST_A, BP) is True
    assert image_current(DIGEST_B, BP) is False
    assert image_current(None, BP) is None          # digest unknown
    assert image_current(DIGEST_A, None) is None    # blueprint unknown
    assert image_current(DIGEST_A, "ghcr.io/x/y:tag") is None  # tag pin


def test_status_route_carries_comparison(client, inspector):
    # FakeInspector.status_many now receives blueprint_image and stamps it.
    client.post("/v1/workspaces", json={
        "id": "proj", "repo": "git@github.com:me/proj", "branch": "main"})
    r = client.get("/v1/containers/status")
    assert r.status_code == 200
    body = r.json()[0]
    assert "image_current" in body and "image_digest" in body
```

For the route test, `FakeInspector.status_many` (conftest) gains the parameter and copies it onto each `WorkspaceStatus` so the test can see it flowed:

```python
    def status_many(self, ids, blueprint_image=None):
        out = []
        for i in ids:
            s = self.statuses.get(i, WorkspaceStatus(id=i, liveness="absent"))
            s.blueprint_image = blueprint_image
            out.append(s)
        return out

    def inspect(self, ws_id, blueprint_image=None):
        return self.inspections.get(ws_id, ContainerInspect(workspace_id=ws_id))
```

The `client`/app fixture must also install a stub `app.state.blueprint_image` whose `get()` returns `None` (no network in tests): add to conftest a tiny `class FakeBlueprintImage: value = None; get = lambda self: self.value` and set it via the same override/wiring path used for the inspector.

- [ ] **Step 2: Run to verify failure**, `uv run pytest tests/test_image_current.py -q`.

- [ ] **Step 3: Implement**

`app/models.py`: add to BOTH `WorkspaceStatus` and `ContainerInspect`:

```python
    # sha256 digest of the image the container runs; None when unknowable
    # (no container, tag-only image, /images blocked by the socket proxy).
    image_digest: str | None = None
    # Blueprint ref at comparison time; None when the blueprint is unreachable.
    blueprint_image: str | None = None
    # Tri-state on purpose: None (unknown) must never render as outdated.
    image_current: bool | None = None
```

`app/docker_inspect.py` module level:

```python
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
```

Instance method on the real inspector:

```python
    def _image_digest(self, c: Container) -> str | None:
        # Config.Image is the ref the container was created from; for the
        # devbox (image-only devcontainer) that is the digest-pinned ref.
        d = _sha256_of(c.attrs.get("Config", {}).get("Image"))
        if d:
            return d
        # Fallback needs /images, which the deployed socket proxy BLOCKS;
        # degrade to unknown rather than erroring the whole status call.
        try:
            repo_digests = (c.image.attrs.get("RepoDigests") or []) if c.image else []
        except Exception:
            return None
        return _sha256_of(repo_digests[0]) if repo_digests else None
```

`status_many(self, ids, blueprint_image=None)`: in the final loop where `WorkspaceStatus` is built, for `c is not None` compute once per container:

```python
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
```

`inspect(self, ws_id, blueprint_image=None)`: after building `info`, set the same three fields from `self._image_digest(c)`. Update the `Inspector` Protocol (line ~63) to the new signatures.

`app/routers/containers.py` status route:

```python
async def status(
    store: StoreDep,
    inspector: InspectorDep,
    blueprint: BlueprintImageDep,
    ids: list[str] | None = Query(default=None),
) -> list[WorkspaceStatus]:
    if ids is None:
        ids = [w.id for w in store.list_workspaces()]
    bp = await run_in_threadpool(blueprint.get)
    return await run_inspect(inspector.status_many, ids, bp)
```

`app/routers/workspaces.py` inspect route: same pattern, `run_inspect(inspector.inspect, ws_id, bp)`.

- [ ] **Step 4: Run to verify pass**, `uv run pytest -q` (full service suite; the FakeInspector signature change touches other tests).
- [ ] **Step 5: Commit**, `git commit -am "feat(catalog): compare container image digest against the blueprint"`

---

### Task 5: Bash, live-branch resolution in `_dvw_pin_state`

**Files:**
- Modify: `lib/pin.sh` (`_dvw_pin_state` + two helpers)
- Test: `tests/bats/pin-sync.bats` (extend)

**Interfaces:**
- Produces: `_dvw_catalog_source_get <id>` / `_dvw_catalog_source_pull <id>` (thin `_catalog_req` wrappers printing the JSON body); `_dvw_pin_state` unchanged output contract (`state\tslug\tbranch\tcur`), but `branch` now prefers the clone's live branch.

- [ ] **Step 1: Write the failing tests**, append to `tests/bats/pin-sync.bats`:

```bash
@test "pin state: prefers the source clone's live branch over the catalog" {
  _dvw_catalog_source_get() {
    jq -n '{present: true, detached: false, branch: "feat/live"}'
  }
  _dvw_repo_pin() {
    [ "$2" = "feat/live" ] || { echo "wrong branch: $2" >&2; return 1; }
    printf '%s\n' "$BP_IMAGE"
  }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == ok$'\t'vossiman/demo$'\t'feat/live* ]]
}

@test "pin state: falls back to the catalog branch when the service is unreachable" {
  _dvw_catalog_source_get() { return 2; }
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  run _dvw_pin_state demo
  [[ "$output" == ok$'\t'vossiman/demo$'\t'main* ]]
}

@test "pin state: detached or absent clone falls back to the catalog branch" {
  _dvw_catalog_source_get() { jq -n '{present: true, detached: true, branch: null}'; }
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  run _dvw_pin_state demo
  [[ "$output" == ok$'\t'vossiman/demo$'\t'main* ]]
}
```

- [ ] **Step 2: Run to verify failure**, `bats tests/bats/pin-sync.bats`. Expected: the three new tests fail (`_dvw_catalog_source_get` unused / wrong branch).

- [ ] **Step 3: Implement**, in `lib/pin.sh`, above `_dvw_pin_state`:

```bash
# Source-clone state / ff-pull via the catalog service. Print the JSON body;
# rc per _catalog_req (2 = unreachable, 1 = HTTP error).
_dvw_catalog_source_get()  { _catalog_req GET  "/v1/workspaces/$1/source"; }
_dvw_catalog_source_pull() { _catalog_req POST "/v1/workspaces/$1/source/pull"; }
```

In `_dvw_pin_state`, after `branch=$(jq -r '.branch // empty' <<<"$ws")` insert:

```bash
  # The clone's live branch is what `devpod up --recreate` builds from; the
  # catalog records only the creation-time branch. Fail-open to the catalog
  # value: unreachable service, absent clone, or detached HEAD change nothing.
  local src live
  if src=$(_dvw_catalog_source_get "$id" 2>/dev/null); then
    live=$(jq -r 'select(.present == true and .detached == false)
                  | .branch // empty' <<<"$src" 2>/dev/null) || live=""
    [[ -n "$live" ]] && branch="$live"
  fi
```

- [ ] **Step 4: Run to verify pass**, `bats tests/bats/pin-sync.bats` (all, including the pre-existing ones, they stub no `_dvw_catalog_source_get`, so add a default stub `_dvw_catalog_source_get() { return 2; }` to `setup()` to keep them hermetic).
- [ ] **Step 5: Commit**, `git commit -am "feat(pin): resolve the live build branch from the source clone"`

---

### Task 6: Bash, `cmd_pin_rebuild` (`lib/pin-rebuild.sh`)

**Files:**
- Create: `lib/pin-rebuild.sh`
- Modify: `dvw` (source the lib after `lib/pin.sh`; dispatch `pin-rebuild)`; add to the no-TUI subcommand list string)
- Modify: `lib/pin.sh` (`_dvw_pin_open_pr`: per-base head branch name), `lib/commands.sh` (`cmd_recreate`: `DVW_SKIP_PIN_PREFLIGHT` guard)
- Test: `tests/bats/pin-rebuild.bats`

**Interfaces:**
- Consumes: `_dvw_blueprint_pin`, `_dvw_repo_slug`, `_dvw_repo_pin`, `_dvw_pin_short`, `_dvw_pin_open_pr` (pin.sh); `_dvw_catalog_source_get/_pull` (Task 5); `cmd_recreate` (commands.sh); `_catalog_req` (catalog-http-lib.sh).
- Produces: `cmd_pin_rebuild <id> [--no-wait] [--timeout <s>]` (exit 0 ok / 1 failed / 2 aborted); helpers `_dvw_pin_digest`, `_dvw_pin_wait_merged`, `_dvw_pin_main_pr`. Env knob `DVW_PIN_REBUILD_POLL_SECS` (default 10).

- [ ] **Step 1: Fix `_dvw_pin_open_pr`'s head-branch collision first (small, blocking bug).** Today the head branch is `$DVW_PIN_BRANCH_PREFIX-<short>` regardless of base. Opening PRs from one head against two bases breaks: the second `PUT contents` uses the OTHER base's blob sha and 409s. In `_dvw_pin_open_pr`, replace the `branch=` line:

```bash
  local base_slug="${base//\//-}"
  local branch="$DVW_PIN_BRANCH_PREFIX-$(_dvw_pin_short "$image")"
  # One head branch per base: a shared head cannot carry different bases'
  # file rewrites (the second PUT 409s on the first PUT's blob). main keeps
  # the historical name so existing open PRs are still recognized.
  [[ "$base" != "main" ]] && branch="$branch-$base_slug"
```

Add a bats test to `tests/bats/pin-sync.bats` asserting the derived branch name differs for `main` vs `feat/x` (extract the name via a `gh` stub that records `pr list --head` arguments, or refactor the name into a helper `_dvw_pin_head_branch <base> <image>` and test that pure function, prefer the helper).

- [ ] **Step 2: Write the failing tests for the command**

```bash
# tests/bats/pin-rebuild.bats
#!/usr/bin/env bats
#
# `dvw pin-rebuild`, the one-stop loop. Everything external is stubbed:
# catalog service, gh, devpod (via cmd_recreate). Follows pin-sync.bats.

setup() {
  source "$DVW_ROOT/dvw"
  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  BP_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'a%.0s' {1..64})"
  OLD_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'b%.0s' {1..64})"
  export BP_IMAGE OLD_IMAGE
  _dvw_blueprint_pin() { printf '%s\n' "$BP_IMAGE"; }
  catalog_workspace_get() {
    jq -n --arg r "git@github.com:vossiman/demo.git" --arg b main \
      '{repo:$r, branch:$b, ide:"ssh"}'
  }
  command() { builtin command "$@"; }
  gh() { :; }   # presence check only; behavior stubbed per test

  # Defaults: current pin everywhere, everything succeeds.
  _dvw_catalog_source_get() {
    jq -n --arg p "$BP_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"main",
        committed_pin:$p, head:"deadbeef"}'
  }
  _dvw_catalog_source_pull() { _dvw_catalog_source_get "$1"; }
  cmd_recreate() { echo "RECREATED $1"; }
  _catalog_req() {  # step-8 inspect
    jq -n --arg d "sha256:$(printf 'a%.0s' {1..64})" '{image_digest:$d}'
  }
  DVW_PIN_REBUILD_POLL_SECS=0
}

@test "current pin: skips PR and pull, rebuilds anyway" {
  _dvw_catalog_source_pull() { echo "PULL SHOULD NOT RUN" >&2; return 1; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current"* ]]
  [[ "$output" != *"PULL SHOULD NOT RUN"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
  [[ "$output" == *"running the blueprint image"* ]]
}

@test "stale pin: PR, merge gate, pull, rebuild, verify" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, dirty:false, branch:"feat/x",
        committed_pin:$p, head:"deadbeef"}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }   # pr view --jq .state
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull/9"* ]]
  [[ "$output" == *"RECREATED demo"* ]]
}

@test "stale pin with --no-wait: opens the PR and stops cleanly" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  run cmd_pin_rebuild demo --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" != *"RECREATED"* ]]
}

@test "pull that does not land the pin stops before the rebuild" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }
  _dvw_catalog_source_pull() {   # pull "succeeds" but pin unchanged
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pins"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "refused pull (dirty clone) is a hard stop naming the reason" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "MERGED"; }
  _dvw_catalog_source_pull() {
    jq -n '{error:"source clone has uncommitted changes; refusing to pull over them"}'
    return 1
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "detached clone is a hard stop" {
  _dvw_catalog_source_get() {
    jq -n '{present:true, detached:true, branch:null, committed_pin:null}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached"* ]]
}

@test "closed-unmerged PR aborts with exit 2" {
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  _dvw_pin_open_pr() { echo "https://github.com/vossiman/demo/pull/9"; }
  _dvw_pin_main_pr() { :; }
  gh() { echo "CLOSED"; }
  run cmd_pin_rebuild demo
  [ "$status" -eq 2 ]
}

@test "dry-run opens and mutates nothing" {
  export DVW_DRY_RUN=1
  _dvw_catalog_source_get() {
    jq -n --arg p "$OLD_IMAGE" \
      '{present:true, detached:false, branch:"main", committed_pin:$p}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" != *"RECREATED"* ]]
}

@test "rebuild landing on the wrong image fails loudly" {
  _dvw_catalog_source_pull() { return 1; }   # unused: pin is current
  _catalog_req() {
    jq -n --arg d "sha256:$(printf 'b%.0s' {1..64})" '{image_digest:$d}'
  }
  run cmd_pin_rebuild demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"blueprint is"* ]]
}
```

- [ ] **Step 3: Run to verify failure**, `bats tests/bats/pin-rebuild.bats`. Expected: `cmd_pin_rebuild: command not found`.

- [ ] **Step 4: Implement `lib/pin-rebuild.sh`**

```bash
#!/usr/bin/env bash
# dvw pin-rebuild, one-stop: resolve the build branch from the source clone,
# PR the stale pin (build branch + main baseline), verify the merge via gh,
# ff-pull the clone, rebuild, and assert the running image. Every step that
# can silently no-op is followed by an assertion; silent no-ops in this chain
# are exactly what shipped stale rebuilds before.
# Spec: docs/superpowers/specs/2026-09-01-pin-rebuild-one-stop-design.md

DVW_PIN_REBUILD_POLL_SECS="${DVW_PIN_REBUILD_POLL_SECS:-10}"

# sha256:<64 hex> component of an image ref; empty output when tag-pinned.
_dvw_pin_digest() {
  [[ "${1:-}" =~ sha256:[0-9a-f]{64} ]] || return 1
  printf '%s\n' "${BASH_REMATCH[0]}"
}

# Poll until the PR is merged. rc 0 merged / 1 timeout or gh failure /
# 2 closed-unmerged. Enter re-checks immediately; Ctrl-C aborts the command.
_dvw_pin_wait_merged() {
  local url="$1" timeout="${2:-1800}" waited=0 state
  ui_info "waiting for merge (Enter re-checks, Ctrl-C aborts): $url"
  while :; do
    state=$(gh pr view "$url" --json state --jq '.state' 2>/dev/null) || state=""
    case "$state" in
      MERGED) return 0 ;;
      CLOSED) ui_error "PR closed without merging: $url"; return 2 ;;
    esac
    (( waited >= timeout )) && { ui_error "timed out after ${timeout}s: $url"; return 1; }
    read -r -t "$DVW_PIN_REBUILD_POLL_SECS" _ 2>/dev/null || true
    waited=$(( waited + DVW_PIN_REBUILD_POLL_SECS ))
  done
}

# Baseline PR against main so future workspaces start current. Never blocks:
# skipped when main is the build branch, already current, or unpinned; a
# failure is a warning, not an error.
_dvw_pin_main_pr() {
  local slug="$1" branch="$2" bp="$3" cur url
  [[ "$branch" == "main" ]] && return 0
  cur=$(_dvw_repo_pin "$slug" main) || {
    ui_status_warn "couldn't read main's pin; skipping the baseline PR"; return 0; }
  [[ -z "$cur" || "$cur" == "$bp" ]] && return 0
  if url=$(_dvw_pin_open_pr "$slug" main "$bp"); then
    [[ -n "$url" ]] && ui_status_ok "baseline PR (main): $url"
  else
    ui_status_warn "couldn't open the baseline PR against main (not blocking)"
  fi
  return 0
}

cmd_pin_rebuild() {
  local id="" timeout=1800 no_wait=0
  while (($#)); do
    case "$1" in
      --no-wait) no_wait=1 ;;
      --timeout) shift; timeout="${1:-1800}" ;;
      -*) ui_error "unknown flag: $1"; return 1 ;;
      *)
        if [[ -n "$id" ]]; then
          ui_error "usage: dvw pin-rebuild <workspace-id> [--no-wait] [--timeout <s>]"
          return 1
        fi
        id="$1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || {
    ui_error "usage: dvw pin-rebuild <workspace-id> [--no-wait] [--timeout <s>]"
    return 1; }
  command -v gh >/dev/null 2>&1 || {
    ui_error "pin-rebuild needs the gh CLI (it opens and watches the PR)"
    return 1; }

  local ws repo slug bp
  ws=$(catalog_workspace_get "$id") || { ui_error "unknown workspace: $id"; return 1; }
  repo=$(jq -r '.repo // empty' <<<"$ws")
  slug=$(_dvw_repo_slug "$repo") || {
    ui_error "$id: $repo is not a GitHub repo; pin-rebuild cannot PR it"; return 1; }
  bp=$(_dvw_blueprint_pin) || {
    ui_error "couldn't read the blueprint pin from $DVW_BLUEPRINT_DEVCONTAINER_URL"
    return 1; }

  # 1. Build branch = the source clone's live HEAD; that is literally what
  #    `devpod up --recreate` reads. Catalog branch only as a warned fallback.
  local src branch committed
  if src=$(_dvw_catalog_source_get "$id" 2>/dev/null); then
    [[ $(jq -r '.present' <<<"$src") == "true" ]] || {
      ui_error "$id: no source clone on the provider; has devpod ever built it?"
      return 1; }
    [[ $(jq -r '.detached' <<<"$src") == "true" ]] && {
      ui_error "$id: source clone is on a detached HEAD; check out a branch first"
      return 1; }
    branch=$(jq -r '.branch // empty' <<<"$src")
    committed=$(jq -r '.committed_pin // empty' <<<"$src")
  else
    branch=$(jq -r '.branch // empty' <<<"$ws")
    committed=""
    ui_status_warn "catalog service unreachable; falling back to catalog branch '$branch' (unverified; the pull step will fail without the service)"
  fi
  [[ -n "$branch" ]] || { ui_error "$id: couldn't resolve a build branch"; return 1; }

  ui_banner "dvw pin-rebuild" "$id, $slug@$branch → $(_dvw_pin_short "$bp")"

  # 2+3. PR only when the working tree's pin differs. When it is already
  # current there is nothing to merge or pull; go straight to the rebuild
  # (the container may still be running the old image).
  local pr_url="" need_sync=0
  if [[ "$committed" == "$bp" ]]; then
    ui_status_ok "committed pin already current on $branch; skipping PR and pull"
  else
    need_sync=1
    ui_action "stale" "$branch pins $(_dvw_pin_short "${committed:-<none>}")"
    pr_url=$(_dvw_pin_open_pr "$slug" "$branch" "$bp") || {
      ui_error "couldn't open the pin PR for $slug@$branch"; return 1; }
    [[ -n "$pr_url" ]] && ui_status_ok "PR: $pr_url"
    _dvw_pin_main_pr "$slug" "$branch" "$bp"
  fi

  if (( need_sync )) && [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would wait for the merge, pull the source clone, rebuild $id, and verify the image"
    return 0
  fi

  if (( need_sync )); then
    # 4. Merge gate, verified via gh; the user's say-so is not an input.
    if [[ -n "$pr_url" ]]; then
      if (( no_wait )); then
        ui_info "--no-wait: merge the PR, then re-run: dvw pin-rebuild $id"
        return 0
      fi
      _dvw_pin_wait_merged "$pr_url" "$timeout" || return $?
      ui_status_ok "merged: $pr_url"
    fi

    # 5. Pull the clone; devpod builds from its working tree.
    local pull_body rc=0
    pull_body=$(_dvw_catalog_source_pull "$id") || rc=$?
    if (( rc != 0 )); then
      local detail
      detail=$(jq -r '.detail // .error // empty' <<<"$pull_body" 2>/dev/null)
      ui_error "couldn't pull the source clone${detail:+: $detail}"
      return 1
    fi
    ui_status_ok "source clone pulled"

    # 6. Assert the working tree now carries the blueprint pin. This is the
    #    assertion that catches a merge that landed somewhere the clone
    #    doesn't point.
    committed=$(jq -r '.committed_pin // empty' <<<"$pull_body")
    if [[ "$committed" != "$bp" ]]; then
      ui_error "after the pull, $branch's working tree still pins $(_dvw_pin_short "${committed:-<none>}"), expected $(_dvw_pin_short "$bp")"
      ui_info "  did the PR target the branch the clone has checked out?"
      return 1
    fi
    ui_status_ok "working tree pin verified"
  fi

  # Dry-run for the already-current path (the stale path returned above).
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    ui_info "[dry-run] would rebuild $id and verify the image"
    return 0
  fi

  # 7. Rebuild. Skip recreate's own preflight; this command IS the preflight.
  DVW_SKIP_PIN_PREFLIGHT=1 cmd_recreate "$id" || return 1

  # 8. Assert the running image.
  local bp_digest digest insp
  if ! bp_digest=$(_dvw_pin_digest "$bp"); then
    ui_status_warn "blueprint pin is not digest-pinned; cannot verify the running image"
    return 0
  fi
  insp=$(_catalog_req GET "/v1/workspaces/$id/inspect" 2>/dev/null) || insp=""
  digest=$(jq -r '.image_digest // empty' <<<"$insp" 2>/dev/null) || digest=""
  if [[ -z "$digest" ]]; then
    ui_status_warn "couldn't read the rebuilt container's image digest; verify manually: dvw status"
    return 0
  fi
  if [[ "$digest" == "$bp_digest" ]]; then
    ui_status_ok "$id is running the blueprint image ($(_dvw_pin_short "$bp"))"
    return 0
  fi
  ui_status_fail "$id rebuilt onto ${digest:0:19}… but the blueprint is ${bp_digest:0:19}…"
  return 1
}
```

`dvw` entrypoint: after the `lib/pin.sh` source line add

```bash
# shellcheck source=lib/pin-rebuild.sh
. "$DVW_ROOT/lib/pin-rebuild.sh"
```

and in the dispatch `case`, after `pin-sync)`:

```bash
    pin-rebuild)
      shift; cmd_pin_rebuild "$@" ;;
```

Also extend the no-TUI usage string (`subcommands: ...`) with `pin-rebuild`.

`lib/commands.sh` `cmd_recreate`: wrap the preflight call:

```bash
  if [[ "${DVW_SKIP_PIN_PREFLIGHT:-}" != "1" ]] \
     && declare -F _dvw_pin_preflight >/dev/null 2>&1; then
    _dvw_pin_preflight "$id" || return 0
  fi
```

- [ ] **Step 5: Run to verify pass**, `bats tests/bats/pin-rebuild.bats tests/bats/pin-sync.bats tests/bats/dispatch.bats`.
- [ ] **Step 6: Commit**, `git commit -am "feat: dvw pin-rebuild, the one-stop pin update and rebuild"`

---

### Task 7: Bash, outdated badge in `dvw status` + preflight handoff

**Files:**
- Modify: `lib/connect-resolver.sh` (`_dvw_load_probe`: parse `image_current`), `lib/connect.sh` (declare `DVW_PROBE_IMAGE_CURRENT`), `lib/ui.sh` (`_dvw_load_running_ids`: `DVW_OUTDATED_IDS`), `lib/commands.sh` (`cmd_status` row + footer), `lib/pin.sh` (`_dvw_pin_preflight` message)
- Test: `tests/bats/resolver.bats` (extend), `tests/bats/pin-sync.bats` (preflight message)

**Interfaces:**
- Consumes: Task 4's `image_current` field in `/v1/containers/status`.
- Produces: `declare -gA DVW_PROBE_IMAGE_CURRENT` (`"true"`/`"false"`, unset = unknown); `DVW_OUTDATED_IDS` (newline list); `dvw status` rows suffixed `⬆` with a footer naming `dvw pin-rebuild <id>`.

- [ ] **Step 1: Write the failing tests**, in `tests/bats/resolver.bats`, mirror the existing `_dvw_load_probe` tests' stub of `_catalog_req` and add:

```bash
@test "probe records image_current per id, tolerating old servers" {
  _catalog_req() {
    case "$2" in
      /v1/containers/status)
        jq -n '[{id:"a", liveness:"alive", image_current:false},
                {id:"b", liveness:"alive", image_current:true},
                {id:"c", liveness:"alive"}]' ;;
      *) echo '[]' ;;
    esac
  }
  _dvw_load_probe
  [ "${DVW_PROBE_IMAGE_CURRENT[a]}" = "false" ]
  [ "${DVW_PROBE_IMAGE_CURRENT[b]}" = "true" ]
  [ -z "${DVW_PROBE_IMAGE_CURRENT[c]:-}" ]
}
```

(Adopt the surrounding tests' exact setup; the file already sources dvw and stubs `_catalog_req`.)

- [ ] **Step 2: Run to verify failure**, `bats tests/bats/resolver.bats`.

- [ ] **Step 3: Implement**

`lib/connect.sh`, next to `declare -gA DVW_PROBE_STATE=()`:

```bash
declare -gA DVW_PROBE_IMAGE_CURRENT=()
```

`lib/connect-resolver.sh` `_dvw_load_probe`: extend the jq line and reader:

```bash
  local id liveness siblings img_cur
  while IFS=$'\t' read -r id liveness siblings img_cur; do
    [[ -z "$id" ]] && continue
    DVW_PROBE_STATE["$id"]="$liveness"
    [[ -n "$siblings" ]] && DVW_PROBE_SIBLINGS["$id"]="$siblings"
    [[ -n "$img_cur" ]] && DVW_PROBE_IMAGE_CURRENT["$id"]="$img_cur"
  done < <(jq -r '.[] | "\(.id)\t\(.liveness)\t\(.running_siblings // "")\t\(.image_current // "")"' <<<"$status_body")
```

(`// ""` not `// empty`, same old-server rationale as the comment above it. jq renders `false` as the string `"false"`, which is exactly what the map stores; only `null`/missing collapses to empty.)

`lib/ui.sh` `_dvw_load_running_ids`, after the state loop:

```bash
  local outdated=()
  for id in "${!DVW_PROBE_IMAGE_CURRENT[@]}"; do
    [[ "${DVW_PROBE_IMAGE_CURRENT[$id]}" == "false" ]] && outdated+=("$id")
  done
  DVW_OUTDATED_IDS=$(printf '%s\n' "${outdated[@]}" | grep -v '^$' | sort -u || true)
```

`lib/commands.sh` `cmd_status`: add `--arg outdated "$DVW_OUTDATED_IDS"` to the jq call, bind `($outdated | lines) as $od`, and change the state expression to append the badge:

```jq
        (.id as $id
         | (if   ($s | index($id)) then "⚠ stale"
            elif ($a | index($id)) then "● running"
            elif ($o | index($id)) then "○ stopped"
            elif ($b | index($id)) then "✗ absent"
            elif ($u | index($id)) then "? unreachable"
            else                        "? unknown" end)
           + (if ($od | index($id)) then " ⬆" else "" end)),
```

Footer, after the absent block:

```bash
  if [[ -n "${DVW_OUTDATED_IDS:-}" ]]; then
    echo
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      ui_status_warn "$id is running an image older than the blueprint, \`dvw pin-rebuild $id\` to update"
    done <<<"$DVW_OUTDATED_IDS"
  fi
```

(Use a comma or colon instead of the em dash in that string.)

`lib/pin.sh` `_dvw_pin_preflight`: change the post-offer hint to

```bash
    ui_info "merge the PR, then: dvw pin-rebuild $id (pulls the source clone and verifies the image)"
```

and update the matching pin-sync.bats assertion.

- [ ] **Step 4: Run to verify pass**, `bats tests/bats/resolver.bats tests/bats/pin-sync.bats` plus a spot-check of the full bats suite: `tests/bats/run.sh`.
- [ ] **Step 5: Commit**, `git commit -am "feat(status): outdated-image badge backed by the blueprint comparison"`

---

### Task 8: TUI, badge, menu entry, action

**Files:**
- Modify: `tui/dvw_tui/client.py` (Workspace field + merge), `tui/dvw_tui/render.py` (`state_cell`), `tui/dvw_tui/screens/main.py` (3 call sites + `u` binding), `tui/dvw_tui/screens/menu.py` (item), `tui/dvw_tui/actions.py` (`pin_rebuild`), `tui/dvw_tui/app.py` (dispatch)
- Test: `tests/test_render.py`, `tests/test_client.py`, `tests/test_menu.py`, `tests/test_actions.py` (extend each)

**Interfaces:**
- Consumes: `image_current` from `/v1/containers/status` (Task 4).
- Produces: `Workspace.image_current: bool | None`; `state_cell(liveness, attached=0, image_current=None)`; `actions.pin_rebuild(workspace_id) -> list[str]`; menu action id `"pin-rebuild"`.

- [ ] **Step 1: Write the failing tests** (one per file, matching each file's existing style):

```python
# tests/test_render.py
def test_state_cell_outdated_badge():
    assert "⬆" in state_cell("alive", 0, image_current=False).plain

def test_state_cell_no_badge_when_current_or_unknown():
    assert "⬆" not in state_cell("alive", 0, image_current=True).plain
    assert "⬆" not in state_cell("alive", 0, image_current=None).plain

# tests/test_client.py (inside the workspaces_with_status test's fake payload,
# add "image_current": False to one status entry and assert)
    assert ws.image_current is False

# tests/test_actions.py
def test_pin_rebuild_argv():
    assert actions.pin_rebuild("ws1") == ["dvw", "pin-rebuild", "ws1"]

# tests/test_menu.py
def test_menu_has_pin_rebuild():
    assert "pin-rebuild" in [a for a, _ in MENU_ITEMS]
```

- [ ] **Step 2: Run to verify failure**, `cd tui && uv run pytest ../tests -q -k "render or actions or menu or client"`.

- [ ] **Step 3: Implement**

`client.py` `Workspace`: add `image_current: bool | None = None  # merged in from /containers/status`; in `workspaces_with_status`:

```python
            v = s.get("image_current")
            w.image_current = v if isinstance(v, bool) else None
```

`render.py`:

```python
def state_cell(liveness: str, attached: int = 0,
               image_current: bool | None = None) -> Text:
    """liveness_cell plus `⇄ N` for attached clients and `⬆` when the
    container runs an image older than the blueprint. Tri-state on purpose:
    None (unknown) renders nothing, only an actual False earns the badge."""
    text = liveness_cell(liveness)
    if attached >= 1 and liveness in ("alive", "stale"):
        text.append(f" {glyph('⇄', str(attached))}", style=f"bold {ACCENT}")
    if image_current is False:
        text.append(f" {glyph('⬆', 'outdated')}", style=f"bold {YELLOW}")
    return text
```

Check `glyphs.py`: `glyph(mark, label)` degrades to the label on non-UTF terminals; if `⬆` is not in its table, follow the existing pattern to add it.

`screens/main.py`: the three `state_cell(...)` call sites (lines ~185, ~330, ~344) pass the value they already have: line 185 has the `Workspace` (`w.image_current`); the refresh paths (330/344) read from the status dict they are iterating (`data.get("image_current")`, coerced with the same `isinstance(v, bool)` guard, factor a tiny module-level `def _tri(v): return v if isinstance(v, bool) else None` in main.py if needed). Add a binding `Binding("u", "pin_rebuild", "update pin")` with:

```python
    def action_pin_rebuild(self) -> None:
        self.app.do_pin_rebuild(self.focused_workspace())
```

`actions.py`:

```python
def pin_rebuild(workspace_id: str) -> list[str]:
    return [dvw_bin(), "pin-rebuild", workspace_id]
```

`menu.py` `MENU_ITEMS`, after `rebuild`:

```python
    ("pin-rebuild", "u      update pin & rebuild"),
```

`app.py`: add

```python
    def do_pin_rebuild(self, workspace: Workspace | None) -> None:
        if workspace is None:
            return
        # Suspend, not confirm: the bash side runs its own interactive merge
        # gate and prints every step; a second confirm here would just nag.
        self._run_suspended(actions.pin_rebuild(workspace.id))
```

and in `open_context_menu`'s `on_result`: `elif action == "pin-rebuild": self.do_pin_rebuild(workspace)`.

- [ ] **Step 4: Run to verify pass**, `cd tui && uv run pytest ../tests -q`.
- [ ] **Step 5: Commit**, `git commit -am "feat(tui): outdated badge and pin-rebuild menu action"`

---

### Task 9: Docs + deploy note

**Files:**
- Modify: `README.md` (subcommand list, if it lists them), `CLAUDE.md` (the pin/stale-image paragraph: name `pin-rebuild` as the closing loop), `KNOWN_ISSUES.md` (if it mentions the stale-pin gap, close it)
- Modify: `catalog-service/deploy/catalog.env.example` (document `CATALOG_DEVPOD_AGENT_WORKSPACES_DIR`, `CATALOG_BLUEPRINT_DEVCONTAINER_URL`, `CATALOG_BLUEPRINT_IMAGE_TTL` with defaults)

- [ ] **Step 1:** Grep each file for `pin-sync` / `rebuild` mentions and update: the documented flow is now `dvw pin-rebuild <id>` (one stop), with `pin-sync` kept for fleet-wide PR sweeps. Mention that the service must be redeployed (`deploy/host-update.sh`) before the new endpoints and badge work, and that old client + new server (and vice versa) degrade to today's behaviour.
- [ ] **Step 2:** `bats tests/bats/run.sh` quick smoke of doc-adjacent tests (deploy-docker-coupling.bats reads the deploy files).
- [ ] **Step 3: Commit**, `git commit -am "docs: pin-rebuild is the one-stop stale-pin flow"`

---

## Final verification (after all tasks)

- [ ] `cd catalog-service && uv run pytest -q`, all green.
- [ ] `cd tui && uv run pytest ../tests -q`, all green.
- [ ] `tests/bats/run.sh`, all green.
- [ ] `shellcheck lib/pin-rebuild.sh lib/pin.sh`, clean (match repo conventions).
- [ ] Manual (needs vossisrv): deploy the service (`deploy/host-update.sh`), `dvw status` shows `⬆` on a stale workspace, `dvw pin-rebuild <id>` end to end, step 8 reports the new digest.
