"""dvw-docker-proxy: allowlisting proxy in front of docker.sock.

The proxy runs in a thread on a temp unix socket; upstream is a scripted fake
on another temp unix socket. Tests speak raw HTTP so what reaches the wire is
exactly what is asserted.
"""

from __future__ import annotations

import json
import socket
import threading
import time

import pytest

from proxy import dvw_docker_proxy as px


class FakeUpstream:
    """Reads one HTTP request per connection, records it, answers from a
    handler. handler(method, path, headers, body, conn) -> bytes | None; when
    it returns None it has written to conn itself (upgrade scenarios)."""

    def __init__(self, path, handler):
        self.path = path
        self.handler = handler
        self.requests: list[tuple[str, str, dict, bytes]] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.sock.settimeout(0.05)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._one, args=(conn,), daemon=True).start()

    def _one(self, conn):
        try:
            req = px.read_request(conn)
        except px.BadRequest:
            conn.close()
            return
        headers = {k.lower(): v for k, v in req.headers}
        self.requests.append((req.method, req.target, headers, req.body))
        resp = self.handler(req.method, req.target, headers, req.body, conn)
        try:
            if resp is not None:
                conn.sendall(resp)
        except OSError:
            pass  # the proxy hung up first, which the relay cap tests arrange
        finally:
            conn.close()

    def close(self):
        self.stop.set()
        self.thread.join(1)
        self.sock.close()


def http(status, body=b"", extra=b""):
    return (f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n").encode() + extra + b"\r\n" + body


def ok_json(obj):
    return http("200 OK", json.dumps(obj).encode())


@pytest.fixture
def stack(tmp_path):
    """Yields (send, upstream) where send(raw_request_bytes) -> raw response."""
    up_path = str(tmp_path / "up.sock")
    px_path = str(tmp_path / "px.sock")
    state = {"handler": lambda m, p, h, b, c: ok_json({"echo": p})}
    upstream = FakeUpstream(up_path, lambda *a: state["handler"](*a))
    listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listen.bind(px_path)
    listen.listen(8)
    stop = threading.Event()
    registry = px.ExecRegistry()
    t = threading.Thread(
        target=px.serve, args=(listen, f"unix:{up_path}", registry, stop), daemon=True)
    t.start()

    def send(raw: bytes) -> bytes:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(3)
        c.connect(px_path)
        c.sendall(raw)
        chunks = []
        while True:
            try:
                d = c.recv(65536)
            except socket.timeout:
                break
            if not d:
                break
            chunks.append(d)
        c.close()
        return b"".join(chunks)

    class Stack:
        pass

    s = Stack()
    s.send = send
    s.upstream = upstream
    s.path = px_path
    s.registry = registry
    s.set_handler = lambda h: state.__setitem__("handler", h)
    yield s
    stop.set()
    listen.close()
    upstream.close()


def req(method, target, body=b"", headers=""):
    return (f"{method} {target} HTTP/1.1\r\nHost: docker\r\n{headers}"
            f"Content-Length: {len(body)}\r\n\r\n").encode() + body


def status_of(resp: bytes) -> int:
    return int(resp.split(b" ", 2)[1])


def body_of(resp: bytes) -> bytes:
    return resp.split(b"\r\n\r\n", 1)[1]


# ---- allowed plain routes --------------------------------------------------

@pytest.mark.parametrize("target", [
    "/_ping", "/version", "/info",
    "/containers/json?all=1&limit=-1&filters=%7B%22label%22%3A%5B%22x%22%5D%7D",
    "/containers/abc123/json",
    "/containers/abc123/stats?stream=false",
    "/containers/abc123/stats?stream=0",
    "/containers/abc123/stats?stream=False",
])
def test_allowed_get_routes_reach_upstream_with_query(stack, target):
    resp = stack.send(req("GET", target))
    assert status_of(resp) == 200
    assert json.loads(body_of(resp)) == {"echo": target}
    assert stack.upstream.requests[-1][1] == target


def test_version_prefix_is_stripped_for_routing_but_forwarded(stack):
    resp = stack.send(req("GET", "/v1.45/_ping"))
    assert status_of(resp) == 200
    assert stack.upstream.requests[-1][1] == "/v1.45/_ping"


def test_response_gets_connection_close(stack):
    resp = stack.send(req("GET", "/_ping"))
    head = resp.split(b"\r\n\r\n", 1)[0] + b"\r\n"
    assert b"\r\nConnection: close\r\n" in head


# ---- denied ----------------------------------------------------------------

@pytest.mark.parametrize("method,target", [
    ("POST", "/containers/create"),
    ("POST", "/containers/abc123/start"),
    ("DELETE", "/containers/abc123"),
    ("GET", "/images/json"),
    ("GET", "/volumes"),
    ("GET", "/networks"),
    ("POST", "/build"),
    ("POST", "/commit"),
    ("GET", "/swarm"),
    ("GET", "/system/df"),
    ("GET", "/events"),
    ("HEAD", "/_ping"),
    ("PUT", "/containers/abc123/archive?path=/"),
    ("GET", "/containers/abc123/stats"),
    ("GET", "/containers/abc123/stats?stream=true"),
    ("GET", "/containers/abc123/logs?stdout=1"),
    ("GET", "/containers/abc123/top"),
    ("GET", "/containers/../json"),
    ("GET", "/containers/abc%2Fjson"),
    ("POST", "/exec/deadbeef/start"),
    ("GET", "/exec/deadbeef/json"),
])
def test_denied_routes_never_reach_upstream(stack, method, target):
    before = len(stack.upstream.requests)
    resp = stack.send(req(method, target, body=b"{}"))
    assert status_of(resp) == 403
    assert body_of(resp) == px.DENY_BODY
    assert len(stack.upstream.requests) == before


def test_malformed_request_line_is_400(stack):
    resp = stack.send(b"GARBAGE\r\n\r\n")
    assert status_of(resp) == 400


def test_oversized_head_is_400(stack):
    resp = stack.send(b"GET /_ping HTTP/1.1\r\nX: " + b"a" * (px.MAX_HEAD + 10) + b"\r\n\r\n")
    assert status_of(resp) == 400


def test_chunked_request_body_is_400(stack):
    resp = stack.send(b"POST /containers/abc/exec HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    assert status_of(resp) == 400


# ---- exec id registry ------------------------------------------------------

def test_exec_registry_expires_and_caps():
    registry = px.ExecRegistry(ttl=60.0, cap=2)
    registry.add("first")
    assert registry.check("first")
    assert not registry.check("never-issued")
    registry.add("second")
    registry.add("third")
    assert not registry.check("first")
    assert registry.check("third")
    time_expired = px.ExecRegistry(ttl=-1.0)
    time_expired.add("stale")
    assert not time_expired.check("stale")


# ---- head/body limits ------------------------------------------------------

def test_large_body_is_not_counted_against_the_head_limit():
    """The 16 KiB cap applies to the request head, not to a body that arrives
    in the same read as the end of the head."""
    left, right = socket.socketpair()
    body = b"x" * px.MAX_BODY
    raw = (b"POST /containers/abc/exec HTTP/1.1\r\nHost: docker\r\n"
           b"Content-Length: %d\r\n\r\n" % len(body)) + body
    sender = threading.Thread(target=left.sendall, args=(raw,), daemon=True)
    sender.start()
    try:
        request = px.read_request(right)
        assert request.body == body
        assert request.path == "/containers/abc/exec"
    finally:
        sender.join(2)
        left.close()
        right.close()


# ---- header smuggling ------------------------------------------------------

@pytest.mark.parametrize("evil", [
    b"X-Foo: a\n\nPOST /containers/create HTTP/1.1\r\nHost: d\r\n"
    b"Content-Length: 2\r\n",
    b"X-Foo: a\rPOST /containers/create HTTP/1.1\r\n",
    b"X-Foo\x00: a\r\n",
    b"X Foo: a\r\n",
])
def test_header_smuggling_is_400_and_never_reaches_upstream(stack, evil):
    before = len(stack.upstream.requests)
    resp = stack.send(b"GET /_ping HTTP/1.1\r\nHost: docker\r\n" + evil
                      + b"Content-Length: 0\r\n\r\n")
    assert status_of(resp) == 400
    assert len(stack.upstream.requests) == before


def test_only_allowlisted_headers_are_forwarded(stack):
    stack.send(req("GET", "/_ping",
                   headers="X-Registry-Auth: secret\r\nUser-Agent: dvw/1\r\n"))
    forwarded = stack.upstream.requests[-1][2]
    assert "x-registry-auth" not in forwarded
    assert forwarded["user-agent"] == "dvw/1"
    assert forwarded["host"] == "docker"


def test_non_numeric_content_length_is_400(stack):
    resp = stack.send(b"POST /containers/abc/exec HTTP/1.1\r\nContent-Length: 1_0\r\n\r\n")
    assert status_of(resp) == 400


def test_duplicate_content_length_is_400(stack):
    resp = stack.send(b"POST /containers/abc/exec HTTP/1.1\r\n"
                      b"Content-Length: 0\r\nContent-Length: 2\r\n\r\n{}")
    assert status_of(resp) == 400


# ---- query smuggling -------------------------------------------------------

@pytest.mark.parametrize("query", [
    "stream=true&stream=false",
    "stream=false&stream=true",
    "stream=false&stream=false",
])
def test_duplicate_stream_param_is_denied(stack, query):
    before = len(stack.upstream.requests)
    resp = stack.send(req("GET", f"/containers/abc123/stats?{query}"))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


def test_single_stream_false_still_passes(stack):
    resp = stack.send(req("GET", "/containers/abc123/stats?stream=false&one-shot=1"))
    assert status_of(resp) == 200


# ---- route anchoring and relay cap -----------------------------------------

def test_trailing_newline_target_is_not_an_allowed_route():
    with pytest.raises(px.Forbidden):
        px.route(px.Request("GET", "/_ping\n", [], b"", b""))


def test_trailing_newline_target_on_the_wire_never_reaches_upstream(stack):
    before = len(stack.upstream.requests)
    resp = stack.send(b"GET /_ping\n HTTP/1.1\r\nHost: docker\r\n\r\n")
    assert status_of(resp) == 400
    assert len(stack.upstream.requests) == before


def test_oversized_response_is_cut_at_max_relay(stack):
    big = b"z" * (px.MAX_RELAY + 50_000)
    stack.set_handler(lambda m, p, h, b, c: http("200 OK", big))
    resp = stack.send(req("GET", "/_ping"))
    assert status_of(resp) == 200
    assert len(body_of(resp)) == px.MAX_RELAY


# ---- exec create -----------------------------------------------------------

DOCKER_PY_EXEC = {
    "Container": "abc123", "User": "", "Privileged": False, "Tty": False,
    "AttachStdin": False, "AttachStdout": True, "AttachStderr": True,
    "Cmd": ["dvw-probe"], "Env": None,
}


def exec_create(stack, body: dict, cid="abc123"):
    return stack.send(req("POST", f"/containers/{cid}/exec",
                          json.dumps(body).encode(),
                          "Content-Type: application/json\r\n"))


def test_exec_probe_is_forwarded_normalized_and_id_registered(stack):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e1"}'))
    resp = exec_create(stack, DOCKER_PY_EXEC)
    assert status_of(resp) == 201
    assert json.loads(body_of(resp)) == {"Id": "e1"}
    m, p, h, b = stack.upstream.requests[-1]
    assert p == "/containers/abc123/exec"
    sent = json.loads(b)
    assert sent["Cmd"] == ["dvw-probe"]
    assert sent["AttachStdout"] is True and sent["AttachStderr"] is True
    assert h["content-length"] == str(len(b))
    assert stack.registry.check("e1")


def test_exec_transitional_tmux_forms_allowed(stack):
    """Only the three argv lists the catalog sends today, byte for byte."""
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e2"}'))
    for cmd in px._TMUX_ALLOWED:
        resp = exec_create(stack, {**DOCKER_PY_EXEC, "Cmd": list(cmd)})
        assert status_of(resp) == 201, cmd


def test_tmux_allowlist_matches_what_the_catalog_sends():
    assert px._TMUX_ALLOWED == (
        ["tmux", "list-sessions", "-F", "#{session_name} #{session_activity}"],
        ["tmux", "list-sessions", "-F", "#{session_name} #{session_attached}"],
        ["tmux", "list-windows", "-t", "work", "-F",
         "#{window_id}\t#{window_name}\t#{window_active}\t#{window_activity}"
         "\t#{@waiting}\t#{pane_current_command}\t#{session_attached}"],
    )


@pytest.mark.parametrize("patch", [
    {"Cmd": ["sh"]},
    {"Cmd": ["sh", "-c", "dvw-probe"]},
    {"Cmd": ["dvw-probe", "--x"]},
    {"Cmd": ["/usr/local/bin/dvw-probe"]},
    {"Cmd": "dvw-probe"},
    {"Cmd": []},
    {"Cmd": ["tmux", "kill-server"]},
    {"Cmd": ["tmux"]},
    # tmux argv is a command language: ";" separates commands and "#(...)" in a
    # format string runs a shell job, so a prefix check would be a shell.
    {"Cmd": ["tmux", "list-sessions", ";", "kill-server"]},
    {"Cmd": ["tmux", "list-sessions", "-F", "#(id)"]},
    {"Cmd": ["tmux", "list-sessions", "-F", "#(id > /tmp/pwned)"]},
    {"Cmd": ["tmux", "list-sessions"]},
    {"Cmd": ["tmux", "list-sessions", "-F", "#{session_name} #{session_activity}",
             ";", "new-session", "-d"]},
    {"Cmd": ["tmux", "list-sessions", "-F", "#{session_name} #{session_activityy}"]},
    {"Cmd": ["tmux", "list-windows", "-t", "work", "-F", "x"]},
    {"Privileged": True},
    {"Tty": True},
    {"AttachStdin": True},
    # 0 == False in Python, so these must be refused by type, not by equality.
    {"Privileged": 0},
    {"Tty": 0.0},
    {"AttachStdin": 1},
    {"User": {}},
    {"WorkingDir": []},
    {"AttachStdout": 1},
    {"AttachStderr": "yes"},
    {"Container": 1},
    {"User": "root"},
    {"User": "0"},
    {"Env": ["LD_PRELOAD=/tmp/x.so"]},
    {"WorkingDir": "/"},
    {"DetachKeys": "ctrl-p"},
])
def test_exec_variants_are_denied_before_upstream(stack, patch):
    before = len(stack.upstream.requests)
    resp = exec_create(stack, {**DOCKER_PY_EXEC, **patch})
    assert status_of(resp) == 403, patch
    assert len(stack.upstream.requests) == before


def test_exec_duplicate_keys_use_last_and_are_normalized(stack):
    # JSON with two Cmd keys: Python keeps the last one, which is the one
    # validated and the only one re-serialized.
    raw = b'{"Cmd":["sh"],"AttachStdout":true,"Cmd":["dvw-probe"]}'
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e3"}'))
    resp = stack.send(req("POST", "/containers/abc123/exec", raw))
    assert status_of(resp) == 201
    assert json.loads(stack.upstream.requests[-1][3])["Cmd"] == ["dvw-probe"]
    assert stack.upstream.requests[-1][3].count(b'"Cmd"') == 1


def test_exec_odd_cased_keys_are_denied(stack):
    before = len(stack.upstream.requests)
    resp = stack.send(req("POST", "/containers/abc123/exec",
                          b'{"cmd":["dvw-probe"]}'))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


def test_exec_smuggled_keys_are_stripped_from_the_forwarded_body(stack):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created", b'{"Id":"e4"}'))
    resp = exec_create(stack, {**DOCKER_PY_EXEC,
                               "HostConfig": {"Privileged": True},
                               "privileged": True})
    assert status_of(resp) == 201
    sent = json.loads(stack.upstream.requests[-1][3])
    assert "HostConfig" not in sent and "privileged" not in sent


@pytest.mark.parametrize("raw", [b"not json", b"[1,2]", b'"str"', b"null", b""])
def test_exec_non_object_body_is_denied(stack, raw):
    before = len(stack.upstream.requests)
    resp = stack.send(req("POST", "/containers/abc123/exec", raw))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


def test_exec_registry_ttl_and_cap():
    reg = px.ExecRegistry(ttl=0.05, cap=2)
    reg.add("a")
    assert reg.check("a")
    reg.add("b")
    reg.add("c")
    assert not reg.check("a") and reg.check("b") and reg.check("c")
    time.sleep(0.08)
    assert not reg.check("c")


def test_exec_non_finite_number_is_denied(stack):
    """Python's json accepts Infinity; the proxy must never re-emit it."""
    before = len(stack.upstream.requests)
    resp = stack.send(req("POST", "/containers/abc123/exec",
                          b'{"Cmd":["dvw-probe"],"AttachStdout":Infinity}'))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


# ---- exec start / inspect ----------------------------------------------------

UPGRADE_HEAD = (b"HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\n"
                b"Content-Type: application/vnd.docker.raw-stream\r\n"
                b"Upgrade: tcp\r\n\r\n")


def _register(stack, exec_id):
    stack.set_handler(lambda m, p, h, b, c: http("201 Created",
                                                 json.dumps({"Id": exec_id}).encode()))
    exec_create(stack, DOCKER_PY_EXEC)


def upgrade_handler(frames: list[bytes], stall: float = 0.0):
    """Answer with 101 and then raw stream bytes, optionally stalling before
    the close so the relay's idle timeout is the thing that ends the copy."""
    def h(m, p, hd, b, conn):
        try:
            conn.sendall(UPGRADE_HEAD)
            for f in frames:
                conn.sendall(f)
            if stall:
                time.sleep(stall)
        except OSError:
            pass  # the proxy cut us off, which is what several tests assert
        conn.close()
        return None
    return h


def recv_until_eof(path, raw, timeout=3.0):
    """Send `raw` and read until the proxy closes. Returns (bytes, eof, secs).
    eof is False when our own socket timeout fired, which is how a test tells
    "the proxy hung up" from "the proxy is still holding the connection"."""
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(path)
    started = time.monotonic()
    c.sendall(raw)
    chunks, eof = [], True
    while True:
        try:
            d = c.recv(65536)
        except socket.timeout:
            eof = False
            break
        if not d:
            break
        chunks.append(d)
    c.close()
    return b"".join(chunks), eof, time.monotonic() - started


def test_exec_start_relays_upgraded_stream(stack):
    _register(stack, "e9")
    # docker multiplexed frame: stream 1 (stdout), 4-byte big-endian length
    frame = b"\x01\x00\x00\x00" + (12).to_bytes(4, "big") + b'{"schema":1}'
    stack.set_handler(upgrade_handler([frame]))
    resp = stack.send(req("POST", "/exec/e9/start", b'{"Detach":false,"Tty":false}',
                          "Connection: Upgrade\r\nUpgrade: tcp\r\n"))
    head, rest = resp.split(b"\r\n\r\n", 1)
    assert head.startswith(b"HTTP/1.1 101")
    assert rest == frame
    assert stack.upstream.requests[-1][1] == "/exec/e9/start"
    assert stack.upstream.requests[-1][2].get("upgrade") == "tcp"
    assert stack.upstream.requests[-1][2].get("connection") == "Upgrade"


def test_exec_start_asks_for_the_upgrade_even_if_the_client_did_not(stack):
    _register(stack, "e9b")
    frame = b"\x01\x00\x00\x00" + (2).to_bytes(4, "big") + b"hi"
    stack.set_handler(upgrade_handler([frame]))
    resp = stack.send(req("POST", "/exec/e9b/start", b"{}"))
    assert resp.split(b"\r\n\r\n", 1)[1] == frame
    assert stack.upstream.requests[-1][2].get("upgrade") == "tcp"


def test_exec_start_does_not_forward_other_client_headers(stack):
    _register(stack, "e9c")
    stack.set_handler(upgrade_handler([b"x"]))
    stack.send(req("POST", "/exec/e9c/start", b"{}",
                   "X-Registry-Auth: secret\r\nUser-Agent: dvw/1\r\n"))
    forwarded = stack.upstream.requests[-1][2]
    assert "x-registry-auth" not in forwarded
    assert forwarded["user-agent"] == "dvw/1"


def test_exec_start_caps_relayed_bytes(stack):
    _register(stack, "e10")
    big = b"\x01\x00\x00\x00" + (2 * px.MAX_RELAY).to_bytes(4, "big") + b"x" * (2 * px.MAX_RELAY)
    stack.set_handler(upgrade_handler([big]))
    resp = stack.send(req("POST", "/exec/e10/start", b"{}"))
    head, rest = resp.split(b"\r\n\r\n", 1)
    assert head.startswith(b"HTTP/1.1 101")
    assert len(rest) == px.MAX_RELAY


def test_exec_start_stalled_upstream_hits_the_idle_timeout(stack, monkeypatch):
    _register(stack, "e10b")
    frame = b"\x02\x00\x00\x00" + (3).to_bytes(4, "big") + b"err"
    stack.set_handler(upgrade_handler([frame], stall=5.0))
    monkeypatch.setattr(px, "RELAY_IDLE_TIMEOUT", 0.1)
    resp, eof, elapsed = recv_until_eof(stack.path,
                                        req("POST", "/exec/e10b/start", b"{}"))
    assert eof, "the proxy must close a stalled relay, not hold the client"
    assert elapsed < 2.0
    assert resp.split(b"\r\n\r\n", 1)[1] == frame


def test_exec_start_detach_true_denied(stack):
    _register(stack, "e11")
    before = len(stack.upstream.requests)
    resp = stack.send(req("POST", "/exec/e11/start", b'{"Detach":true}'))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


def test_exec_start_plain_error_response_is_forwarded(stack):
    _register(stack, "e12")
    stack.set_handler(lambda m, p, h, b, c: http("409 Conflict", b'{"message":"not running"}'))
    resp = stack.send(req("POST", "/exec/e12/start", b"{}"))
    assert status_of(resp) == 409
    assert b"not running" in body_of(resp)
    assert b"\r\nConnection: close\r\n" in resp.split(b"\r\n\r\n", 1)[0] + b"\r\n"


def test_exec_start_plain_response_is_capped(stack):
    _register(stack, "e12b")
    stack.set_handler(lambda m, p, h, b, c: http("200 OK", b"y" * (px.MAX_RELAY + 5000)))
    resp = stack.send(req("POST", "/exec/e12b/start", b"{}"))
    assert status_of(resp) == 200
    assert len(body_of(resp)) == px.MAX_RELAY


def test_exec_inspect_for_registered_id(stack):
    _register(stack, "e13")
    stack.set_handler(lambda m, p, h, b, c: ok_json({"ExitCode": 0, "Running": False}))
    resp = stack.send(req("GET", "/exec/e13/json"))
    assert status_of(resp) == 200
    assert json.loads(body_of(resp))["ExitCode"] == 0


def test_exec_id_from_one_container_cannot_be_started_after_ttl(stack):
    stack.registry._ttl = 0.01
    _register(stack, "e14")
    time.sleep(0.03)
    before = len(stack.upstream.requests)
    resp = stack.send(req("POST", "/exec/e14/start", b"{}"))
    assert status_of(resp) == 403
    assert len(stack.upstream.requests) == before


# ---- upstream failures -------------------------------------------------------

@pytest.fixture
def thread_errors(monkeypatch):
    """Collects exceptions that escape a worker thread, so a test can assert
    the proxy answered rather than died."""
    errs = []
    monkeypatch.setattr(threading, "excepthook", errs.append)
    return errs


def hangup_handler(partial: bytes = b""):
    """Answer with nothing, or half a head, and close: dockerd going away."""
    def h(m, p, hd, b, conn):
        if partial:
            conn.sendall(partial)
        conn.close()
        return None
    return h


@pytest.mark.parametrize("partial", [b"", b"HTTP/1.1 200 OK\r\nContent-Len"])
def test_upstream_hangup_on_a_plain_route_is_502(stack, thread_errors, partial):
    stack.set_handler(hangup_handler(partial))
    resp = stack.send(req("GET", "/_ping"))
    assert status_of(resp) == 502
    assert body_of(resp) == px.GATEWAY_BODY
    assert thread_errors == []


def test_upstream_hangup_on_exec_create_is_502(stack, thread_errors):
    stack.set_handler(hangup_handler())
    resp = exec_create(stack, DOCKER_PY_EXEC)
    assert status_of(resp) == 502
    assert thread_errors == []


def test_upstream_hangup_on_exec_start_is_502(stack, thread_errors):
    _register(stack, "e15")
    stack.set_handler(hangup_handler())
    resp = stack.send(req("POST", "/exec/e15/start", b"{}"))
    assert status_of(resp) == 502
    assert thread_errors == []


@pytest.mark.parametrize("garbage", [
    b"GARBAGE\r\nContent-Length: 0\r\n\r\n",
    b"HTTP/1.1 twohundred\r\n\r\n",
    b"\r\n\r\n",
])
def test_upstream_garbage_status_line_is_502(stack, thread_errors, garbage):
    _register(stack, "e16")
    stack.set_handler(lambda m, p, h, b, c: garbage)
    for target in ("/containers/abc123/exec", "/exec/e16/start"):
        resp = stack.send(req("POST", target,
                              json.dumps(DOCKER_PY_EXEC).encode()
                              if "exec" == target.rsplit("/", 1)[-1] else b"{}"))
        assert status_of(resp) == 502, (target, garbage)
    assert thread_errors == []


def test_upstream_oversized_head_is_502(stack, thread_errors):
    stack.set_handler(lambda m, p, h, b, c:
                      b"HTTP/1.1 200 OK\r\nX: " + b"a" * (px.MAX_HEAD + 10) + b"\r\n\r\n")
    resp = stack.send(req("GET", "/_ping"))
    assert status_of(resp) == 502
    assert thread_errors == []


def test_exec_start_stream_stops_at_the_wall_clock_deadline(stack, monkeypatch):
    """A trickle that never goes quiet long enough for the idle timeout still
    has to end: the relay is bounded in wall clock too."""
    _register(stack, "e17")
    frame = b"\x01\x00\x00\x00" + (1).to_bytes(4, "big") + b"."
    stack.set_handler(dribble_handler(frame, gap=0.02, count=500))
    monkeypatch.setattr(px, "RELAY_IDLE_TIMEOUT", 5.0)
    monkeypatch.setattr(px, "RELAY_MAX_SECONDS", 0.3)
    resp, eof, elapsed = recv_until_eof(stack.path,
                                        req("POST", "/exec/e17/start", b"{}"))
    assert eof, "the proxy must close once the deadline passes"
    assert elapsed < 3.0
    stream = resp.split(b"\r\n\r\n", 1)[1]
    assert 0 < len(stream) < px.MAX_RELAY  # ended on the clock, not the cap


def dribble_handler(frame: bytes, gap: float, count: int):
    """101, then one small frame every `gap` seconds: never idle, never done."""
    def h(m, p, hd, b, conn):
        try:
            conn.sendall(UPGRADE_HEAD)
            for _ in range(count):
                conn.sendall(frame)
                time.sleep(gap)
        except OSError:
            pass  # expected: the proxy closes on us at the deadline
        conn.close()
        return None
    return h
