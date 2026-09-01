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


def test_failed_fetch_negative_caches_within_failure_ttl(monkeypatch):
    # An empty cache with the URL down must not re-fetch on every call: that
    # would mean every status/inspect request re-hits a dead endpoint with
    # timeout=10 under one lock while it's down.
    cache, calls = _cache(monkeypatch, [OSError("down")], ttl=900.0)
    assert cache.get() is None
    assert cache.get() is None
    assert calls["n"] == 1


def test_failed_fetch_retries_after_failure_ttl(monkeypatch):
    cache, calls = _cache(
        monkeypatch, [OSError("down"), '{"image": "%s"}' % PIN], ttl=900.0)
    times = iter([0.0, 61.0])
    monkeypatch.setattr("app.blueprint_image.time.monotonic", lambda: next(times))
    assert cache.get() is None
    assert calls["n"] == 1
    assert cache.get() == PIN
    assert calls["n"] == 2


def test_jsonc_fallback(monkeypatch):
    cache, _ = _cache(
        monkeypatch, ['{ // hi\n "image": "%s" }' % PIN], ttl=0.0)
    assert cache.get() == PIN
