#!/usr/bin/env python3
"""Minimal TCP relay: listen on LPORT, forward to 127.0.0.1:RPORT.
Killing this process cuts the transport under any connection through it."""
import socket, sys, threading

lport, rport = int(sys.argv[1]), int(sys.argv[2])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", lport)); srv.listen(5)

def pump(a, b):
    try:
        while (data := a.recv(65536)):
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

while True:
    client, _ = srv.accept()
    up = socket.create_connection(("127.0.0.1", rport))
    for pair in ((client, up), (up, client)):
        threading.Thread(target=pump, args=pair, daemon=True).start()
