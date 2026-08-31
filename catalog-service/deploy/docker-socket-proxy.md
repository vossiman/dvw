# Docker access: the socket proxy is mandatory

Membership in the `docker` group is **root-equivalent**: anyone who can talk to
`/var/run/docker.sock` can start a container that bind-mounts `/` and reads and
writes the host as root. The catalog service therefore has **no** docker-group
membership, and reaches Docker only through
[`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy).

This is not optional. Without the proxy running, the service cannot reach
Docker at all and every workspace reports as absent. `host-install.sh` starts
it and fails the install if it does not come up.

## Compose

The real file is `deploy/docker-proxy.compose.yml`, pinned by digest rather
than by a moving tag. Start it with:

```bash
docker compose -f /opt/dvw-catalog/deploy/docker-proxy.compose.yml up -d
```

## Wiring

`deploy/catalog.env.example` ships `CATALOG_DOCKER_HOST=tcp://127.0.0.1:2375`
as the default. `dvw-catalog.service` carries no `SupplementaryGroups=docker`;
do not re-add it.

The unit keeps `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, which the
loopback tcp proxy needs.

## Residual risk: EXEC is still required

The proxy runs at `CONTAINERS + EXEC + INFO`, not fully read-only, because
`app/docker_inspect.py` still execs into containers for tmux state:

| Call site | Data | Host-side replaceable? |
|---|---|---|
| `_tmux_work_activity` | `work` session activity epoch | Only via a snapshot written from inside |
| `_tmux_work_attached` | attached client count | No |
| `_work_session_windows` | per-window id, name, active, activity, `@waiting`, command | No |

`_workspaces_owner` used to be a fourth; it now stats the bind-mount `Source`
host-side and needs no exec.

An earlier revision of this document proposed closing `EXEC` with a host-side
`stat` of the tmux socket. **That is not sufficient.** A `stat` yields an
mtime, which can stand in for the activity epoch, but it cannot yield an
attached count or a window list, and the tree view and the waiting-window
indicator both consume the window list.

Reaching a `CONTAINERS`-only proxy requires a **snapshot file written from
inside the container** by a tmux hook, into a host-visible path, which the
catalog then reads directly. aiCodingBaseSetup already carries the tmux hook
infrastructure this would extend (`configs/tmux/tmux.conf` sets hooks on
`client-attached`, `alert-activity`, `alert-silence`, `alert-bell` and
`after-select-window`), and `~/.aicodingsetup` is already a host bind mount
shared by every container, so it is a natural destination that does not
pollute the workspace checkout.

That work spans two repos and is **not** scheduled. Until it lands, `EXEC: 1`
and `POST: 1` stay, and the honest posture is: the proxy removes host-root
equivalence, but an attacker with the proxy endpoint can still exec into
containers it can see.
