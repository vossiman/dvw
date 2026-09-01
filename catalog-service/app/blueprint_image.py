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
