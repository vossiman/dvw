#!/usr/bin/env python3
"""dvw-clipd — images-only clipboard server over a local unix socket.

Serves the client machine's clipboard to devpod containers through the ssh
reverse forward added by the managed blueprint (v3):

    RemoteForward /tmp/dvw-clip.sock %d/.dvw/clip.sock

Endpoints (HTTP/1.1 over the unix socket; curl --unix-socket is the client):
    GET /targets            image/* MIME types currently on the clipboard
    GET /clip?type=<mime>   raw bytes for one image type (404 if absent)
    anything else           403

Images-only is enforced HERE, on the client — the trust boundary. Container
processes can never read text (passwords) through this socket, no matter what
they send. Spec: docs/superpowers/specs/2026-08-27-clipboard-bridge-design.md
"""

import argparse
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler

SUBPROCESS_TIMEOUT = 5

# WSL without Windows PATH interop (appendWindowsPath=false, or a daemon
# started from an environment that stripped /mnt/c/...) has no powershell.exe
# on PATH — resolve it explicitly. Overridable for tests/exotic installs.
_POWERSHELL_FALLBACK = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"


def _powershell():
    override = os.environ.get("DVW_CLIPD_POWERSHELL")
    if override:
        return override
    found = shutil.which("powershell.exe")
    if found:
        return found
    if os.path.exists(_POWERSHELL_FALLBACK):
        return _POWERSHELL_FALLBACK
    return None


def _run(cmd, **kwargs):
    return subprocess.run(
        cmd, capture_output=True, timeout=SUBPROCESS_TIMEOUT, **kwargs
    )


class Backend:
    """Interface: targets() -> [mime, ...] (unfiltered), fetch(mime) -> bytes|None."""


class WaylandBackend(Backend):
    def targets(self):
        p = _run(["wl-paste", "-l"])
        if p.returncode != 0:
            return []
        return p.stdout.decode(errors="replace").split()

    def fetch(self, mime):
        p = _run(["wl-paste", "--type", mime])
        if p.returncode != 0 or not p.stdout:
            return None
        return p.stdout


class X11Backend(Backend):
    def targets(self):
        p = _run(["xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"])
        if p.returncode != 0:
            return []
        return p.stdout.decode(errors="replace").split()

    def fetch(self, mime):
        p = _run(["xclip", "-selection", "clipboard", "-t", mime, "-o"])
        if p.returncode != 0 or not p.stdout:
            return None
        return p.stdout


# Alpha-preserving read: browsers/snipping tools put a "PNG" clipboard format
# alongside the alpha-less DIB that GetImage() reads; try it first. Must be
# powershell.exe (5.1) — pwsh 7 dropped image clipboard support.
_PSH_GRAB = """
Add-Type -AssemblyName System.Windows.Forms;
$out = '{win_path}';
$data = [System.Windows.Forms.Clipboard]::GetDataObject();
if ($data -ne $null -and $data.GetDataPresent('PNG')) {{
  $ms = $data.GetData('PNG');
  if ($ms -ne $null) {{
    $fs = [System.IO.File]::Create($out);
    $ms.CopyTo($fs); $fs.Close(); exit 0
  }}
}}
$img = [System.Windows.Forms.Clipboard]::GetImage();
if ($img -eq $null) {{ exit 1 }};
$img.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
"""

# Sent to powershell VERBATIM — single braces. (Only _PSH_GRAB goes through
# .format() and therefore escapes its braces.)
_PSH_PROBE = """
Add-Type -AssemblyName System.Windows.Forms;
$data = [System.Windows.Forms.Clipboard]::GetDataObject();
if ($data -ne $null -and ($data.GetDataPresent('PNG') -or
    [System.Windows.Forms.Clipboard]::ContainsImage())) { exit 0 };
exit 1
"""


class WslBackend(Backend):
    def targets(self):
        psh = _powershell()
        if psh is None:
            return []
        p = _run([psh, "-NoProfile", "-Command", _PSH_PROBE])
        return ["image/png"] if p.returncode == 0 else []

    def fetch(self, mime):
        psh = _powershell()
        if psh is None or mime != "image/png":
            return None
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            out = f.name
        try:
            wp = _run(["wslpath", "-w", out])
            if wp.returncode != 0:
                return None
            win_path = wp.stdout.decode().strip()
            p = _run(
                [psh, "-NoProfile", "-Command",
                 _PSH_GRAB.format(win_path=win_path.replace("'", "''"))]
            )
            if p.returncode != 0:
                return None
            with open(out, "rb") as fh:
                data = fh.read()
            return data or None
        finally:
            os.unlink(out)


def pick_backend():
    forced = os.environ.get("DVW_CLIPD_BACKEND", "")
    if forced == "wsl":
        return WslBackend()
    if forced == "wayland":
        return WaylandBackend()
    if forced == "x11":
        return X11Backend()
    # WSL first: under WSLg both WAYLAND_DISPLAY and wl-paste can be present,
    # but the WSLg bridge exposes clipboard images as image/bmp only — the
    # powershell path is the one that actually works.
    try:
        with open("/proc/version") as f:
            if "microsoft" in f.read().lower():
                return WslBackend()
    except OSError:
        pass
    if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste"):
        return WaylandBackend()
    if shutil.which("xclip"):
        return X11Backend()
    if shutil.which("wl-paste"):
        return WaylandBackend()
    return None


def _image_targets(backend):
    return [t for t in backend.targets() if t.split(";")[0].startswith("image/")]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet; stdout goes to a logfile anyway
        pass

    def _respond(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Crash-proof by contract: an exception here kills the connection
        # mid-request and the container-side curl sees "empty reply", which
        # reads as a broken bridge. A missing tool (powershell.exe off PATH
        # on WSL, live failure 2026-08-27) must degrade to "no image", and
        # anything unexpected must answer 500, not die silently.
        try:
            self._do_get_inner()
        except Exception:
            traceback.print_exc()
            try:
                self._respond(500, b"clipd internal error (see clipd.log)\n")
            except OSError:
                pass

    def _do_get_inner(self):
        backend = self.server.backend
        parsed = urllib.parse.urlparse(self.path)
        if backend is None:
            self._respond(500, b"no clipboard backend available\n")
            return
        if parsed.path == "/targets":
            try:
                targets = _image_targets(backend)
            except (subprocess.TimeoutExpired, OSError):
                targets = []
            body = "".join(f"{t}\n" for t in targets)
            self._respond(200, body.encode())
            return
        if parsed.path == "/clip":
            mime = urllib.parse.parse_qs(parsed.query).get("type", [""])[0]
            # The images-only boundary: nothing but image/* ever leaves.
            if not mime.startswith("image/"):
                self._respond(403, b"images only\n")
                return
            try:
                data = backend.fetch(mime)
            except (subprocess.TimeoutExpired, OSError):
                data = None
            if not data:
                self._respond(404, b"no image on the clipboard\n")
                return
            self._respond(200, data, ctype=mime)
            return
        self._respond(403, b"images only\n")


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True

    def __init__(self, sock_path, backend):
        self.backend = backend
        super().__init__(sock_path, Handler)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--socket",
        default=os.path.join(os.path.expanduser("~"), ".dvw", "clip.sock"),
    )
    args = ap.parse_args()

    sock_dir = os.path.dirname(args.socket)
    os.makedirs(sock_dir, mode=0o700, exist_ok=True)
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass

    backend = pick_backend()
    if backend is None:
        print("dvw-clipd: no clipboard tool found", file=sys.stderr)

    server = UnixHTTPServer(args.socket, backend)
    os.chmod(args.socket, 0o600)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.unlink(args.socket)
        except OSError:
            pass


if __name__ == "__main__":
    main()
