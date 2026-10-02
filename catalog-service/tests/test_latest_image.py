from __future__ import annotations

import json

import pytest

from app.latest_image import LatestImage, LatestImageCache, image_current, resolve

TOP, PLAT, CFG = ("sha256:" + c * 64 for c in "abc")
OTHER = "sha256:" + "f" * 64
DOCKER_V2 = "application/vnd.docker.distribution.manifest.v2+json"
OCI_INDEX = "application/vnd.oci.image.index.v1+json"


def _registry(monkeypatch, manifests):
    """manifests: ref -> (digest, body). Records every URL requested."""
    seen = []

    def fake_http(url, headers):
        seen.append(url)
        if "/token?" in url:
            return {}, json.dumps({"token": "t"}).encode()
        assert headers["Authorization"] == "Bearer t"
        digest, body = manifests[url.rsplit("/manifests/", 1)[1]]
        return {"docker-content-digest": digest}, json.dumps(body).encode()

    monkeypatch.setattr("app.latest_image._http", fake_http)
    return seen


def test_single_manifest_yields_manifest_and_config_digest(monkeypatch):
    seen = _registry(monkeypatch, {
        "latest": (TOP, {"mediaType": DOCKER_V2, "config": {"digest": CFG}}),
    })
    got = resolve("ghcr.io/vossiman/devbox-base:latest", "amd64")
    assert got == LatestImage(ref=f"ghcr.io/vossiman/devbox-base@{TOP}",
                              digests=frozenset({TOP, CFG}))
    assert seen[0] == "https://ghcr.io/token?scope=repository:vossiman/devbox-base:pull"


def test_index_adds_the_host_platform_manifest(monkeypatch):
    _registry(monkeypatch, {
        "latest": (TOP, {"mediaType": OCI_INDEX, "manifests": [
            {"digest": OTHER, "platform": {"os": "unknown", "architecture": "unknown"}},
            {"digest": PLAT, "platform": {"os": "linux", "architecture": "amd64"}},
        ]}),
        PLAT: (PLAT, {"config": {"digest": CFG}}),
    })
    got = resolve("ghcr.io/x/y:latest", "amd64")
    assert got.digests == {TOP, PLAT, CFG}


def test_index_without_host_platform_fails(monkeypatch):
    _registry(monkeypatch, {
        "latest": (TOP, {"mediaType": OCI_INDEX, "manifests": [
            {"digest": PLAT, "platform": {"os": "linux", "architecture": "arm64"}}]}),
    })
    with pytest.raises(ValueError, match="linux/amd64"):
        resolve("ghcr.io/x/y:latest", "amd64")


def test_only_ghcr_references_are_accepted():
    with pytest.raises(ValueError, match="ghcr.io"):
        resolve("quay.io/x/y:latest", "amd64")


def test_bad_digest_header_fails(monkeypatch):
    _registry(monkeypatch, {"latest": ("latest", {"config": {"digest": CFG}})})
    with pytest.raises(ValueError):
        resolve("ghcr.io/x/y:latest", "amd64")


def test_image_current_compares_digests_never_tag_strings():
    latest = LatestImage(ref="ghcr.io/x/y@" + TOP, digests=frozenset({TOP, CFG}))
    assert image_current({CFG}, latest) is True       # classic store image ID
    assert image_current({TOP}, latest) is True       # containerd store image ID
    assert image_current({OTHER}, latest) is False
    assert image_current(set(), latest) is None       # nothing known about the container
    assert image_current({CFG}, None) is None         # registry unknown


def test_cache_serves_last_good_value_on_failure(monkeypatch):
    good = LatestImage(ref="r", digests=frozenset({TOP}))
    results = [good, OSError("down")]

    def fake_resolve(image):
        r = results.pop(0)
        if isinstance(r, Exception):
            raise r
        return r

    monkeypatch.setattr("app.latest_image.resolve", fake_resolve)
    cache = LatestImageCache("ghcr.io/x/y:latest", ttl=0.0)
    assert cache.get() == good
    assert cache.get() == good


def test_cache_none_before_first_success(monkeypatch):
    def down(image):
        raise OSError("down")
    monkeypatch.setattr("app.latest_image.resolve", down)
    assert LatestImageCache("ghcr.io/x/y:latest", 900.0).get() is None


def test_status_route_reports_latest_ref(client, latest_image):
    latest_image.value = LatestImage(ref="ghcr.io/x/y@" + TOP, digests=frozenset({TOP}))
    client.post("/v1/workspaces", json={
        "id": "proj", "repo": "git@github.com:me/proj", "branch": "main"})
    body = client.get("/v1/containers/status").json()[0]
    assert body["latest_image"] == "ghcr.io/x/y@" + TOP
    assert "pin_current" not in body
