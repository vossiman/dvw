#!/usr/bin/python3
"""dvw-docker-proxy: the only path from the dvw catalog service to Docker.

Listens on a unix socket that systemd creates with mode 0600 for the catalog
user, talks to /var/run/docker.sock as a member of the docker group, and
forwards exactly the routes the catalog needs. Everything else is refused
before the upstream is contacted. Exec is restricted to one command
(`dvw-probe`, plus a transitional tmux form), so a compromised catalog can
read tmux state and nothing more. Stdlib only; runs with /usr/bin/python3.

Spec: docs/superpowers/specs/2026-09-01-docker-proxy-probe-design.md.
"""
from __future__ import annotations

import json
import logging
import os
import re
import socket
import sys
import threading
import time

log = logging.getLogger("dvw-docker-proxy")

MAX_HEAD = 16 * 1024
MAX_BODY = 64 * 1024
MAX_RELAY = 1024 * 1024
EXEC_TTL = 60.0
EXEC_CAP = 256
DENY_BODY = b'{"message":"dvw-docker-proxy: route not allowed"}'
BAD_BODY = b'{"message":"dvw-docker-proxy: malformed request"}'

# Container and exec ids: hex digests in practice, but names are accepted too.
# The leading class excludes a leading dot, so "." and ".." never match.
_ID = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
_VERSION_PREFIX = re.compile(r"^/v\d+\.\d+(?=/)")
_ROUTES = [
    ("GET", re.compile(r"/_ping\Z"), "plain"),
    ("GET", re.compile(r"/version\Z"), "plain"),
    ("GET", re.compile(r"/info\Z"), "plain"),
    ("GET", re.compile(r"/containers/json\Z"), "plain"),
    ("GET", re.compile(rf"/containers/(?P<cid>{_ID})/json\Z"), "plain"),
    ("GET", re.compile(rf"/containers/(?P<cid>{_ID})/stats\Z"), "stats"),
    ("POST", re.compile(rf"/containers/(?P<cid>{_ID})/exec\Z"), "exec_create"),
    ("POST", re.compile(rf"/exec/(?P<eid>{_ID})/start\Z"), "exec_start"),
    ("GET", re.compile(rf"/exec/(?P<eid>{_ID})/json\Z"), "exec_inspect"),
]
_STREAM_OFF = {"false", "0", "False"}
# RFC 7230 field-name token, and the only headers forwarded upstream. The
# catalog needs no others, and an allowlist means a header this proxy has
# never reasoned about cannot reach dockerd.
_TOKEN = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")
_DIGITS = re.compile(r"[0-9]+")
_FORWARD_HEADERS = ("host", "content-type", "accept", "user-agent")

# Exec create bodies. docker-py sends User: "", Env: null and Privileged:
# false explicitly, so "absent or false" and "absent or empty" have to accept
# those spellings rather than requiring the key to be missing. The checks are
# by type, not by equality: 0 == False in Python, so an equality test would
# let {"Privileged": 0} through.
# The tmux forms are the exact argv lists catalog-service/app/docker_inspect.py
# sends today, matched whole. Nothing looser will do: tmux argv is a command
# language, where a ";" element separates commands and a "#(...)" sequence in
# a -F format string runs a shell job, so any prefix match is a shell.
# Absent or empty, checked against each field's real Docker API type, so an
# empty value of the wrong type ({"User": {}}) is refused rather than waved
# through as "empty".
_EMPTY_TYPES = {"User": str, "Env": list, "WorkingDir": str, "DetachKeys": str}
_TMUX_ALLOWED = (
    ["tmux", "list-sessions", "-F", "#{session_name} #{session_activity}"],
    ["tmux", "list-sessions", "-F", "#{session_name} #{session_attached}"],
    ["tmux", "list-windows", "-t", "work", "-F",
     "#{window_id}\t#{window_name}\t#{window_active}\t#{window_activity}"
     "\t#{@waiting}\t#{pane_current_command}\t#{session_attached}"],
)
_PASSTHROUGH = ("Container", "AttachStdout", "AttachStderr", "Tty", "Privileged",
                "AttachStdin", "User", "Env", "WorkingDir", "DetachKeys", "Cmd")


class BadRequest(Exception):
    pass


class Forbidden(Exception):
    pass


class Request:
    __slots__ = ("method", "target", "path", "query", "headers", "body", "head")

    def __init__(self, method, target, headers, body, head):
        self.method = method
        self.target = target
        path, _, query = target.partition("?")
        self.path = _VERSION_PREFIX.sub("", path)
        self.query = query
        self.headers = headers
        self.body = body
        self.head = head


class Route:
    __slots__ = ("kind", "container_id", "exec_id")

    def __init__(self, kind, container_id=None, exec_id=None):
        self.kind = kind
        self.container_id = container_id
        self.exec_id = exec_id


def _recv_until(sock, marker, limit):
    """Read until `marker`; returns (head including marker, bytes read past it).

    The limit counts head bytes only, so a large body arriving in the same
    read as the end of a small head is not mistaken for an oversized head.
    """
    buf = b""
    while True:
        end = buf.find(marker)
        if (len(buf) if end == -1 else end) > limit:
            raise BadRequest("head too large")
        if end != -1:
            return buf[:end + len(marker)], buf[end + len(marker):]
        chunk = sock.recv(4096)
        if not chunk:
            if not buf:
                raise BadRequest("empty")
            raise BadRequest("truncated head")
        buf += chunk


def _recv_exact(sock, n, initial):
    buf = initial
    while len(buf) < n:
        chunk = sock.recv(min(65536, n - len(buf)))
        if not chunk:
            raise BadRequest("truncated body")
        buf += chunk
    return buf[:n], buf[n:]


def _check_no_control_bytes(line: str, what: str) -> None:
    """Reject anything a downstream parser could read as a line break.

    The head is split on CRLF, so a CR, LF or NUL left inside a line was
    smuggled: Go's net/textproto, which is what dockerd parses with, ends a
    header line on a bare LF and would see a second request there. Every
    other control byte is refused too, since none belongs in the four
    headers this proxy forwards.
    """
    for ch in line:
        if (ch < " " and ch != "\t") or ch == "\x7f":
            raise BadRequest(f"control byte in {what}")


def read_request(sock) -> Request:
    head, rest = _recv_until(sock, b"\r\n\r\n", MAX_HEAD)
    lines = head.decode("latin-1").split("\r\n")
    _check_no_control_bytes(lines[0], "request line")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1.") or not parts[1].startswith("/"):
        raise BadRequest("bad request line")
    method, target = parts[0], parts[1]
    if not _TOKEN.fullmatch(method):
        raise BadRequest("bad method")
    if any(ch <= " " or ch == "\x7f" for ch in target):
        raise BadRequest("control byte in target")
    headers = []
    length = 0
    have_length = False
    for line in lines[1:]:
        if not line:
            continue
        _check_no_control_bytes(line, "header")
        name, sep, value = line.partition(":")
        if not sep:
            raise BadRequest("bad header")
        if not _TOKEN.fullmatch(name):
            raise BadRequest("bad header name")
        value = value.strip()
        headers.append((name, value))
        lname = name.lower()
        if lname == "transfer-encoding":
            raise BadRequest("chunked request bodies are not accepted")
        if lname == "content-length":
            if have_length:
                raise BadRequest("duplicate content-length")
            if not _DIGITS.fullmatch(value):
                raise BadRequest("bad content-length")
            length = int(value)
            have_length = True
            if length > MAX_BODY:
                raise BadRequest("body too large")
    body, _ = _recv_exact(sock, length, rest)
    return Request(method, target, headers, body, head)


def route(req: Request) -> Route:
    for method, pattern, kind in _ROUTES:
        if req.method != method:
            continue
        m = pattern.match(req.path)
        if not m:
            continue
        cid = m.groupdict().get("cid")
        eid = m.groupdict().get("eid")
        if kind == "stats":
            stream = [p.partition("=")[2] for p in req.query.split("&")
                      if p.partition("=")[0] == "stream"]
            # Go's url.Values.Get takes the first value, so a duplicate key
            # would let "stream=true&stream=false" pass a last-wins check and
            # then stream forever. Refuse rather than guess.
            if len(stream) != 1 or stream[0] not in _STREAM_OFF:
                raise Forbidden("stats without exactly one stream=false")
            return Route("plain", container_id=cid)
        return Route(kind, container_id=cid, exec_id=eid)
    raise Forbidden(f"{req.method} {req.path}")


class ExecRegistry:
    """Exec ids this proxy handed out, so a fabricated id cannot be started."""

    def __init__(self, ttl=EXEC_TTL, cap=EXEC_CAP):
        self._ttl = ttl
        self._cap = cap
        self._ids = {}
        self._lock = threading.Lock()

    def add(self, exec_id: str) -> None:
        now = time.monotonic()
        with self._lock:
            for k in [k for k, t in self._ids.items() if now - t > self._ttl]:
                del self._ids[k]
            while len(self._ids) >= self._cap:
                del self._ids[next(iter(self._ids))]
            self._ids[exec_id] = now

    def check(self, exec_id: str) -> bool:
        now = time.monotonic()
        with self._lock:
            t = self._ids.get(exec_id)
            return t is not None and now - t <= self._ttl


def validate_exec_body(body: bytes) -> tuple[bytes, str]:
    """Check an exec create body and return (re-serialized body, label).

    The body that goes upstream is rebuilt from the fields checked here, so a
    key this proxy never reasoned about (or a duplicate, or one that differs
    only in case) cannot ride along to dockerd. Raises Forbidden to deny.
    """
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Forbidden("exec body is not JSON") from None
    if not isinstance(data, dict):
        raise Forbidden("exec body is not an object")
    cmd = data.get("Cmd")
    if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
        raise Forbidden("Cmd must be a non-empty list of strings")
    if cmd == ["dvw-probe"]:
        label = "dvw-probe"
    elif cmd in _TMUX_ALLOWED:
        label = f"tmux {cmd[1]}"  # transitional, removed with the catalog fallback
    else:
        raise Forbidden(f"Cmd not allowed: {cmd[0]!r}")
    for key in ("Privileged", "Tty", "AttachStdin"):
        value = data.get(key)
        if not (value is None or value is False):
            raise Forbidden(f"{key} must be absent or false")
    for key, empty_type in _EMPTY_TYPES.items():
        value = data.get(key)
        if not (value is None or (isinstance(value, empty_type) and not value)):
            raise Forbidden(f"{key} must be absent or empty")
    for key in ("AttachStdout", "AttachStderr"):
        if key in data and not isinstance(data[key], bool):
            raise Forbidden(f"{key} must be a boolean")
    if "Container" in data and not isinstance(data["Container"], str):
        raise Forbidden("Container must be a string")
    clean = {k: data[k] for k in _PASSTHROUGH if k in data}
    try:
        # allow_nan=False: Python's json reads and writes Infinity and NaN,
        # which are not JSON and which Go would reject. Never emit them.
        out = json.dumps(clean, separators=(",", ":"), allow_nan=False)
    except ValueError:
        raise Forbidden("exec body is not serializable as JSON") from None
    return out.encode("utf-8"), label


def connect_upstream(upstream: str) -> socket.socket:
    if upstream.startswith("unix:"):
        path = upstream[len("unix:"):]
        if path.startswith("//"):  # unix:///run/docker.sock
            path = path[2:]
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        return s
    if upstream.startswith("tcp://"):
        host, _, port = upstream[len("tcp://"):].partition(":")
        return socket.create_connection((host, int(port)), timeout=10)
    raise ValueError(f"unsupported upstream {upstream!r}")


def _send_response(sock, status: str, body: bytes) -> None:
    head = (f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
    try:
        sock.sendall(head + body)
    except OSError:
        pass


def _rebuild_head(req: Request, body: bytes) -> bytes:
    """Request head for the upstream: same target, only allowlisted headers
    kept, Content-Length rewritten for the (possibly normalized) body."""
    out = [f"{req.method} {req.target} HTTP/1.1"]
    for name, value in req.headers:
        if name.lower() not in _FORWARD_HEADERS:
            continue
        out.append(f"{name}: {value}")
    out.append(f"Content-Length: {len(body)}")
    out.append("Connection: close")
    return ("\r\n".join(out) + "\r\n\r\n").encode("latin-1")


def _read_response_head(up) -> tuple[bytes, bytes]:
    return _recv_until(up, b"\r\n\r\n", MAX_HEAD)


def _with_connection_close(head: bytes) -> bytes:
    lines = [line for line in head.decode("latin-1").split("\r\n")
             if line and not line.lower().startswith("connection:")]
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def _drain(sock, initial: bytes = b"") -> bytes:
    """Read to EOF, but never buffer more than MAX_RELAY."""
    out = initial
    while len(out) < MAX_RELAY:
        chunk = sock.recv(65536)
        if not chunk:
            break
        out += chunk
    return out[:MAX_RELAY]


def _relay_plain(client, up, req: Request, body: bytes) -> None:
    up.sendall(_rebuild_head(req, body) + body)
    head, rest = _read_response_head(up)
    client.sendall(_with_connection_close(head) + rest[:MAX_RELAY])
    sent = len(rest)
    while sent < MAX_RELAY:
        chunk = up.recv(65536)
        if not chunk:
            return
        client.sendall(chunk[:MAX_RELAY - sent])
        sent += len(chunk)
    log.info("verdict=cut path=%s reason=response over %d bytes",
             req.path, MAX_RELAY)


def _relay_exec_create(client, up, req: Request, body: bytes,
                       registry: ExecRegistry) -> None:
    """Forward the validated body, then remember the id Docker handed back."""
    up.sendall(_rebuild_head(req, body) + body)
    head, rest = _read_response_head(up)
    payload = _drain(up, rest)
    if head.split(b" ", 2)[1] == b"201":
        try:
            exec_id = json.loads(_strip_chunked(head, payload)).get("Id")
        except ValueError:
            exec_id = None
        if isinstance(exec_id, str):
            registry.add(exec_id)
    client.sendall(_with_connection_close(head) + payload)


def _relay_exec_start(client, up, req: Request, body: bytes) -> None:
    raise Forbidden("exec start not implemented yet")  # replaced in Task 5


def _check_exec_start_body(body: bytes) -> None:
    """Exec start must stay attached, so the proxy sees the whole output."""
    try:
        opts = json.loads(body or b"{}")
    except ValueError:
        raise Forbidden("exec start body is not JSON") from None
    if not isinstance(opts, dict) or opts.get("Detach") not in (None, False):
        raise Forbidden("exec start must not detach")


def _decide(req: Request, registry: ExecRegistry) -> tuple[Route, bytes, str]:
    """Route the request and validate its body. Raises Forbidden to deny."""
    r = route(req)
    body, label = req.body, ""
    if r.kind == "exec_create":
        body, label = validate_exec_body(req.body)
    elif r.kind in ("exec_start", "exec_inspect"):
        if not registry.check(r.exec_id):
            raise Forbidden("unknown exec id")
        if r.kind == "exec_start":
            _check_exec_start_body(body)
    return r, body, label


def handle_connection(client, upstream: str, registry: ExecRegistry) -> None:
    try:
        client.settimeout(30)
        try:
            req = read_request(client)
        except BadRequest as e:
            log.info("verdict=bad reason=%s", e)
            _send_response(client, "400 Bad Request", BAD_BODY)
            return
        try:
            r, body, label = _decide(req, registry)
        except Forbidden as e:
            log.info("verdict=deny method=%s path=%s reason=%s",
                     req.method, req.target[:200], e)
            _send_response(client, "403 Forbidden", DENY_BODY)
            return
        log.info("verdict=allow method=%s path=%s%s", req.method, req.path,
                 f" cmd={label}" if label else "")
        up = connect_upstream(upstream)
        try:
            up.settimeout(30)
            if r.kind == "exec_start":
                _relay_exec_start(client, up, req, body)
            elif r.kind == "exec_create":
                _relay_exec_create(client, up, req, body, registry)
            else:
                _relay_plain(client, up, req, body)
        finally:
            up.close()
    except OSError as e:
        log.debug("connection error: %s", e)
    finally:
        try:
            client.close()
        except OSError:
            pass


def _strip_chunked(head: bytes, payload: bytes) -> bytes:
    """Docker answers exec create with Content-Length, but tolerate chunked."""
    if b"transfer-encoding: chunked" not in head.lower():
        return payload
    out = b""
    rest = payload
    while rest:
        size_line, _, rest = rest.partition(b"\r\n")
        size = int(size_line.split(b";")[0], 16)
        if size == 0:
            break
        out += rest[:size]
        rest = rest[size + 2:]
    return out


def serve(listen_sock, upstream: str, registry: ExecRegistry, stop: threading.Event) -> None:
    listen_sock.settimeout(0.5)
    while not stop.is_set():
        try:
            client, _ = listen_sock.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=handle_connection, args=(client, upstream, registry),
                         daemon=True).start()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    upstream = os.environ.get("DVW_PROXY_UPSTREAM", "unix:/var/run/docker.sock")
    if os.environ.get("LISTEN_FDS") == "1" and os.environ.get("LISTEN_PID") in (None, str(os.getpid())):
        listen = socket.socket(fileno=3)
    else:
        path = os.environ.get("DVW_PROXY_LISTEN")
        if not path:
            print("dvw-docker-proxy: no LISTEN_FDS and no DVW_PROXY_LISTEN", file=sys.stderr)
            return 2
        if os.path.exists(path):
            os.unlink(path)
        listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listen.bind(path)
        os.chmod(path, 0o600)
        listen.listen(64)
    log.info("dvw-docker-proxy listening, upstream=%s", upstream)
    serve(listen, upstream, ExecRegistry(), threading.Event())
    return 0


if __name__ == "__main__":
    sys.exit(main())
