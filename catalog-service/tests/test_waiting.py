from __future__ import annotations

from app.models import WaitingWindow


def test_waiting_endpoint_returns_flagged_windows(client, inspector):
    inspector.waiting = [
        WaitingWindow(workspace_id="devmachine", container_id="c1",
                      window_id="@7", window_name="feat-notify",
                      waiting_since=1754700000),
    ]
    r = client.get("/v1/containers/waiting")
    assert r.status_code == 200
    body = r.json()
    assert body[0]["workspace_id"] == "devmachine"
    assert body[0]["window_id"] == "@7"


def test_waiting_endpoint_empty(client, inspector):
    assert client.get("/v1/containers/waiting").json() == []
