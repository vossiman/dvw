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
