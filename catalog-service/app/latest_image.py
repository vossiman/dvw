"""TTL-cached digests of the newest devbox image, read from the registry.

Workspaces run `<repo>:latest`, and the build only moves that tag after its
smoke test passes, so the tag IS the newest green build. A tag is a name, not
an identity: comparing it as a string says nothing, so it is resolved to every
digest a running container could report for it:

- the top-level manifest (or index) digest, which is the image ID on Docker's
  containerd image store and what a pull records;
- for an index, the per-platform manifest digest for this host's arch;
- the image config digest, which is the image ID on the classic store.

One refresh serves every client and status row; a failure serves the last
good value, or None when there is none. stdlib urllib on purpose.
"""

from __future__ import annotations

import json
import logging
import platform
import re
import threading
import time
import urllib.request
from dataclasses import dataclass

log = logging.getLogger(__name__)

_FETCH_TIMEOUT = 5.0
_DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
# GHCR only: its anonymous token endpoint is fixed, where other registries
# advertise theirs through a WWW-Authenticate challenge this does not follow.
_REF_RE = re.compile(r"^(?P<host>ghcr\.io)/(?P<repo>[a-z0-9._/-]+):(?P<tag>[A-Za-z0-9._-]+)$")
_INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
_ACCEPT = ", ".join(_INDEX_TYPES + (
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))
_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


@dataclass(frozen=True)
class LatestImage:
    ref: str                    # "<host>/<repo>@<top-level digest>"
    digests: frozenset[str]


def image_current(running: set[str], latest: LatestImage | None) -> bool | None:
    """Tri-state: None when either side is unknown, never a guess."""
    if latest is None or not running:
        return None
    return not running.isdisjoint(latest.digests)


def _http(url: str, headers: dict[str, str]) -> tuple[dict[str, str], bytes]:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=_FETCH_TIMEOUT) as resp:  # noqa: S310
        return {k.lower(): v for k, v in resp.headers.items()}, resp.read()


def _digest(value: object) -> str:
    if not isinstance(value, str) or not _DIGEST_RE.fullmatch(value):
        raise ValueError(f"registry returned an invalid digest: {value!r}")
    return value


def resolve(image: str, arch: str | None = None) -> LatestImage:
    m = _REF_RE.match(image)
    if m is None:
        raise ValueError(f"not a ghcr.io/<repo>:<tag> reference: {image!r}")
    host, repo, tag = m["host"], m["repo"], m["tag"]
    arch = arch or _ARCH.get(platform.machine().lower(), "amd64")

    _, body = _http(f"https://{host}/token?scope=repository:{repo}:pull", {})
    token = json.loads(body)["token"]
    auth = {"Authorization": f"Bearer {token}", "Accept": _ACCEPT}

    def manifest(ref: str) -> tuple[str, dict]:
        headers, body = _http(f"https://{host}/v2/{repo}/manifests/{ref}", auth)
        return _digest(headers.get("docker-content-digest")), json.loads(body)

    top, doc = manifest(tag)
    digests = {top}
    if doc.get("mediaType") in _INDEX_TYPES or "manifests" in doc:
        picked = next(
            (d for d in doc.get("manifests", [])
             if (d.get("platform") or {}).get("os") == "linux"
             and (d.get("platform") or {}).get("architecture") == arch),
            None,
        )
        if picked is None:
            raise ValueError(f"{image} has no linux/{arch} manifest")
        platform_digest, doc = manifest(_digest(picked.get("digest")))
        digests.add(platform_digest)
    digests.add(_digest((doc.get("config") or {}).get("digest")))
    return LatestImage(ref=f"{host}/{repo}@{top}", digests=frozenset(digests))


class LatestImageCache:
    # Failures negative-cache for a shorter window than a good lookup, so a
    # registry outage is retried soon without a lookup per status call.
    _FAILURE_TTL_CAP = 60.0

    def __init__(self, image: str, ttl: float) -> None:
        self._image = image
        self._ttl = ttl
        self._lock = threading.Lock()
        self._refresh_lock = threading.Lock()
        self._value: LatestImage | None = None
        self._fetched_at: float | None = None
        self._last_fetch_ok = False
        self._refreshing = False

    def _fresh_locked(self, now: float) -> bool:
        if self._fetched_at is None:
            return False
        ttl = self._ttl if self._last_fetch_ok else min(self._ttl, self._FAILURE_TTL_CAP)
        return now - self._fetched_at < ttl

    def get(self) -> LatestImage | None:
        """Refresh synchronously, preserving the last good value."""
        with self._refresh_lock:
            with self._lock:
                if self._fresh_locked(time.monotonic()):
                    return self._value
            try:
                value = resolve(self._image)
            except Exception as exc:
                log.warning("Latest image lookup failed for %s: %s", self._image, exc)
                with self._lock:
                    self._fetched_at = time.monotonic()
                    self._last_fetch_ok = False
                    return self._value
            with self._lock:
                self._fetched_at = time.monotonic()
                self._last_fetch_ok = True
                self._value = value
                return value

    def _background_refresh(self) -> None:
        try:
            self.get()
        finally:
            with self._lock:
                self._refreshing = False

    def get_cached(self) -> LatestImage | None:
        """Return immediately and start at most one refresh when stale."""
        with self._lock:
            if self._fresh_locked(time.monotonic()):
                return self._value
            value = self._value
            start = not self._refreshing
            self._refreshing = True
        if start:
            worker = threading.Thread(
                target=self._background_refresh,
                name="dvw-latest-image-refresh",
                daemon=True,
            )
            try:
                worker.start()
            except Exception:
                with self._lock:
                    self._refreshing = False
                log.warning("Latest image refresh worker could not start")
        return value

    @property
    def refresh_in_progress(self) -> bool:
        with self._lock:
            return self._refreshing
