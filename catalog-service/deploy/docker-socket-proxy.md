# Hardening: front Docker with a read-mostly socket proxy

Membership in the `docker` group is **root-equivalent** — anyone who can talk to
`/var/run/docker.sock` can start a container that bind-mounts `/` and reads/writes
the host as root. The catalog service only needs to *list*, *inspect*, and *exec*
(for the tmux probe). [`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
lets us expose exactly that and deny the rest, after which the service no longer
needs the `docker` group at all.

## Compose

```yaml
# /opt/dvw-catalog/deploy/docker-proxy.compose.yml
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    environment:
      CONTAINERS: 1   # GET /containers/json + /containers/{id}/json  (list + inspect)
      EXEC: 1         # POST /exec                                    (tmux activity probe)
      POST: 1         # exec creation is a POST; required only because of EXEC
      INFO: 1         # GET /info + /_ping                            (health)
      # everything else denied:
      IMAGES: 0
      VOLUMES: 0
      NETWORKS: 0
      BUILD: 0
      COMMIT: 0
      SERVICES: 0
      SWARM: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "127.0.0.1:2375:2375"   # loopback only
```

```bash
docker compose -f /opt/dvw-catalog/deploy/docker-proxy.compose.yml up -d
```

## Wire the service to it

In `/opt/dvw-catalog/catalog.env`:

```ini
CATALOG_DOCKER_HOST=tcp://127.0.0.1:2375
```

Then in `dvw-catalog.service`, **remove** `SupplementaryGroups=docker` and
`systemctl daemon-reload && systemctl restart dvw-catalog`. The service can no
longer reach the raw socket; it only sees the whitelisted endpoints.

## Residual risk

`EXEC` is the one privileged hole that can't be closed while the tmux-activity
tie-break uses `docker exec`. To reach a fully read-only (`CONTAINERS`-only)
proxy, move the tmux-activity read to a host-side `stat` of the tmux socket /
heartbeat file under the workspace bind-mount `Source` (it's host-visible because
the service runs on the box). That's a future upgrade; `CONTAINERS + EXEC + INFO`
is the pragmatic posture for the single-user box today.
