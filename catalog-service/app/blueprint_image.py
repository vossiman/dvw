"""TTL-cached blueprint image ref, fetched from the aicoding blueprint's
devcontainer.json. One fetch serves every client and every status row; a
fetch failure serves the last good value, or None when there is none.
stdlib urllib on purpose: no runtime dependency for one GET."""

from __future__ import annotations

import json
import logging
import re
import subprocess
import threading
import time
import urllib.request

_IMAGE_RE = re.compile(r'"image"\s*:\s*"([^"]+)"')
log = logging.getLogger(__name__)

# Must stay well under the catalog clients' 10s request budget (see
# tui/dvw_tui/client.py) so a dead blueprint host degrades to unknown
# instead of failing the whole /containers/status call.
_FETCH_TIMEOUT = 3.0
# Leave room for the existing three-second blueprint fetch inside the TUI
# client's ten-second catalog request budget.
_SELECT_TIMEOUT = 5.0
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_AICODING_RAW_PREFIX = (
    "https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/"
)
_AICODING_RAW_URL_RE = re.compile(
    re.escape(_AICODING_RAW_PREFIX) + r"[0-9a-f]{40}/devcontainer\.json"
)


def _fetch(url: str, timeout: float) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310
        return resp.read().decode("utf-8", "replace")


def _select_sha() -> str | None:
    try:
        result = subprocess.run(  # noqa: S603
            ["timeout", str(_SELECT_TIMEOUT), "aicoding-select", "aicoding"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=_SELECT_TIMEOUT + 1.0,
            check=False,
        )
    except OSError as exc:
        raise RuntimeError("aicoding-select process could not start") from exc
    except subprocess.SubprocessError as exc:
        raise RuntimeError("aicoding-select process timed out") from exc
    sha = result.stdout.strip()
    if result.returncode == 127:
        raise RuntimeError("aicoding-select command is unavailable")
    return sha if result.returncode == 0 and _SHA_RE.fullmatch(sha) else None


def _blueprint_url(configured_url: str) -> str:
    if configured_url:
        if not _AICODING_RAW_URL_RE.fullmatch(configured_url):
            raise ValueError(
                "configured blueprint URL is not an immutable supported URL"
            )
        return configured_url
    sha = _select_sha()
    if sha is None:
        raise RuntimeError("aicoding-select did not return a CI-qualified SHA")
    return f"{_AICODING_RAW_PREFIX}{sha}/devcontainer.json"


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
    # Failures negative-cache for a shorter window than a good fetch, so a
    # down blueprint URL doesn't get re-fetched (timeout=_FETCH_TIMEOUT, one
    # lock held) on every single status/inspect call while it's down.
    _FAILURE_TTL_CAP = 60.0

    def __init__(self, url: str, ttl: float) -> None:
        self._url = url
        self._ttl = ttl
        self._lock = threading.Lock()
        self._value: str | None = None
        self._fetched_at: float | None = None
        self._last_fetch_ok = False

    def get(self) -> str | None:
        """Blocking; call via run_in_threadpool from async code."""
        with self._lock:
            now = time.monotonic()
            if self._fetched_at is not None:
                ttl = self._ttl if self._last_fetch_ok else min(
                    self._ttl, self._FAILURE_TTL_CAP)
                if now - self._fetched_at < ttl:
                    return self._value
            try:
                url = _blueprint_url(self._url)
                image = _parse_image(_fetch(url, timeout=_FETCH_TIMEOUT))
            except Exception as exc:
                log.warning("Blueprint image refresh failed: %s", exc)
                self._fetched_at = now      # negative-cache the failure
                self._last_fetch_ok = False
                return self._value          # stale (or None) beats nothing
            self._fetched_at = now
            self._last_fetch_ok = True
            if image is not None:
                self._value = image
            return self._value
