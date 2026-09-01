# Docker access: the socket proxy is mandatory

The catalog service has **no** docker-group membership and reaches Docker only
through
[`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy).

This is not optional. Without the proxy running, the service cannot reach
Docker at all and every workspace reports as absent. `host-install.sh` starts
it and fails the install if it does not come up.

## What this actually buys you

Read this before deciding to deploy. The trade is real but it is smaller than
"the proxy fixes the docker group", and it is not purely a win.

**What it does buy.** The proxy narrows the API surface. `/images`,
`/volumes`, `/networks`, `/build`, `/commit`, `/events`, swarm, configs and
secrets are all denied. A compromised catalog service, or anything else that
finds the endpoint, can reach a much smaller API than the raw socket offers:
no image pulls or builds, no named-volume mounts, no swarm state.

**What it does NOT buy: it does not remove host-root equivalence.** Upstream's
ACL is path-prefix plus method, not per-endpoint:

```
http-request deny unless METH_GET || { env(POST) -m bool }
http-request allow if { path,url_dec -m reg -i ^(/v[\d\.]+)?/containers } { env(CONTAINERS) -m bool }
```

Once `POST: 1` is on — and it is, because `EXEC` needs it — `CONTAINERS: 1`
permits **every** verb under `/containers`, not just `GET`. Verified through
the proxy at exactly the shipped env set: `POST /containers/create` with
`{"Binds": ["/:/host"]}` returned `201`, `POST /containers/{id}/start`
returned `204`, and the resulting container read `/host/etc/shadow`. With
`"User": "0"` that is host root, the same power docker-group membership had.

A corollary: `ALLOW_START`, `ALLOW_STOP` and `ALLOW_RESTARTS` are dead letters
in this configuration. They only narrow anything when `POST` is off.

**It also changes the access-control model, and not only for the better.**
Docker-group membership was at least gated: you had to be in the group. The
proxy publishes an unauthenticated TCP port on `127.0.0.1:2375`, and a
loopback port has no ACL — any local account or process on the host can reach
it. On a single-admin box that is a small change; on a box with other users or
other services, it is a widening.

Restoring an ACL means fronting the proxy with a **unix socket owned by the
service user at mode 0600** instead of publishing a TCP port (haproxy can bind
a unix socket; the container would share a host directory rather than a port,
and `CATALOG_DOCKER_HOST` would become a `unix://` URL). That is **tracked
separately and not done here.**

Net: deploy this if you want the reduced API surface and accept that the
catalog service still holds a path to host root. Do not deploy it believing
the privilege is gone.

## Compose

The real file is `deploy/docker-proxy.compose.yml`, pinned by digest rather
than by a moving tag. Start it with:

```bash
docker compose -f /opt/dvw-catalog/deploy/docker-proxy.compose.yml up -d --renew-anon-volumes
```

`--renew-anon-volumes` is required, not optional: `haproxy.cfg.template`
lives inside the anonymous `/usr/local/etc/haproxy` volume, so without it a
digest bump keeps the old volume and renders the ACL from a stale template.
`host-install.sh` already passes this flag.

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
and `POST: 1` stay — and `POST: 1` is exactly what makes `CONTAINERS: 1`
root-equivalent, per "What this actually buys you" above. So dropping `EXEC`
is not a nice-to-have tidy-up: it is the prerequisite for turning `POST` off,
which is in turn the prerequisite for the proxy actually constraining
privilege rather than only narrowing the API surface.
