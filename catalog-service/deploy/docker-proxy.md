# Docker access: dvw-docker-proxy

The catalog service never touches `docker.sock`. It talks to
`dvw-docker-proxy` (`catalog-service/proxy/dvw_docker_proxy.py`) over
`/run/dvw-docker-proxy/docker.sock`, a unix socket systemd creates with mode
0600 for the service user. The proxy runs as the system user `dvw-proxy`, the
only non-root member of the docker group, and forwards exactly these routes:

| Method | Path | Note |
|---|---|---|
| GET | `/_ping`, `/version`, `/info` | docker-py handshake |
| GET | `/containers/json` | list |
| GET | `/containers/{id}/json` | inspect |
| GET | `/containers/{id}/stats?stream=false` | cpu and memory for the inspect view |
| POST | `/containers/{id}/exec` | body must be `Cmd == ["dvw-probe"]` (transitional: `tmux list-sessions` / `list-windows`); no `Privileged`, `Tty`, `AttachStdin`, `User`, `Env`, `WorkingDir` |
| POST | `/exec/{id}/start` | only ids this proxy issued in the last 60 s |
| GET | `/exec/{id}/json` | same |

Everything else is `403` and never reaches dockerd. Every request is logged
to the journal with one of these verdicts:

| Verdict | Meaning |
|---|---|
| `allow` | request matched a route and was forwarded |
| `deny` | request did not match any route (`403`) |
| `bad` | request could not be parsed (malformed or smuggled headers) |
| `cut` | a response or exec stream was truncated at its size or time cap |
| `upstream-error` | dockerd (or the connection to it) failed after a request was allowed |

## What this buys

A compromised catalog service can list containers, inspect them, read their
stats, and run `dvw-probe` inside them. It cannot create containers, mount
host paths, pull images, or run any other command. Host-root equivalence is
gone; the previous tecnativa proxy (removed 2026-09) could not do this
because its ACL was path-prefix plus method, so `POST /containers/*/exec`
also allowed `POST /containers/create`.

Access control is the socket's mode bits: only the service user can connect.
The old loopback TCP port had none.

## Adding a route

Add a row to `_ROUTES` in `dvw_docker_proxy.py` with a test in
`tests/test_proxy.py` for both the allowed shape and the nearest denied
neighbour. Prefer extending `dvw-probe` (aiCodingBaseSetup `bin/dvw-probe`)
over adding write routes: the probe runs inside the container and cannot
escalate.

## Migration from tecnativa

Re-run `/opt/dvw/catalog-service/deploy/host-install.sh` once. It creates
`dvw-proxy`, installs and starts the socket unit, rewrites
`CATALOG_DOCKER_HOST` in `catalog.env`, and removes the
`deploy-docker-proxy-1` container. Verify afterwards:

    ss -xl | grep dvw-docker-proxy                    # the new socket is there
    ss -ltn | grep 127.0.0.1:2375                     # MUST print nothing
    id dvw-proxy                                      # the service user exists
    id -nG "$USER" | tr ' ' '\n' | grep -x docker     # MUST print nothing
    curl -fsS --unix-socket /run/dvw-docker-proxy/docker.sock http://localhost/_ping

The two "must print nothing" checks are the ones that say the old path is
really gone: port 2375 was the tecnativa proxy's unauthenticated Docker API on
loopback, and membership of the `docker` group is root equivalence for the
login user. Both greps exit 1 when they print nothing, which is the pass.
