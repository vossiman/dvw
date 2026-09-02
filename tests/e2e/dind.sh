#!/usr/bin/env bash
# End-to-end: dvw-docker-proxy + catalog-service against a docker:dind daemon
# hosting two fake workspace containers with dvw-probe installed. Asserts the
# happy path through the catalog API and the refused attacks straight at the
# proxy socket. Run from the dvw checkout root in the dev container.
#
#   tests/e2e/dind.sh           # run, assert, tear down
#   tests/e2e/dind.sh --keep    # leave running, print the TUI playtest env
#   tests/e2e/dind.sh --down    # tear down a kept run
#
# How dind is reached: the dind container gets its own bridge network and
# publishes nothing; this dev container talks to its bridge IP on port 2375
# with DOCKER_TLS_CERTDIR= (verified working here on docker 29.7.2). If a host
# ever cannot route to that IP, publish the port instead: add
# `-p 127.0.0.1:0:2375` to the `docker run` below and set DIND_ADDR to
# "$(ip route | awk '/default/{print $3}'):$(docker port "$DIND" 2375 | ...)".
#
# The workspace image is built by the OUTER docker and piped into dind with
# `docker save | docker load`: dind starts on a fresh volume every run, so
# building inside it would repeat the apt-get on every invocation, while the
# outer daemon keeps its build cache.
#
# Every docker object and the state dir are named after a per-run prefix
# (DVW_E2E_PREFIX, default dvw-e2e-$$) so a concurrent run or a stale leftover
# cannot collide. Teardown is idempotent.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
POINTER="${DVW_E2E_POINTER:-/tmp/dvw-e2e-last}"
PROBE_SRC="${DVW_PROBE_SRC:-/workspaces/devmachine/devpod/aicoding/bin/dvw-probe}"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

set_names() {
  DIND="$PREFIX-dind"
  NET="$PREFIX-net"
  VOL="$PREFIX-dind-data"
  IMG="$PREFIX-workspace"
  STATE="$E2E_ROOT/state"
}

down() {
  log "teardown"
  if [ -f "$STATE/pids" ]; then
    while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done < "$STATE/pids"
  fi
  # The uvicorn pid above is the one we started, but a crashed run may have
  # left one behind. The socket path is unique per run, so this cannot match
  # another run's process.
  pkill -f -- "--uds $E2E_ROOT/catalog.sock" 2>/dev/null || true
  docker rm -f "$DIND" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker rmi -f "$IMG" >/dev/null 2>&1 || true
  rm -rf "$E2E_ROOT"
  if [ -f "$POINTER" ] && [ "$(cat "$POINTER" 2>/dev/null)" = "$E2E_ROOT" ]; then
    rm -f "$POINTER"
  fi
}

MODE=run
KEEP=0
case "${1:-}" in
  --down) MODE=down ;;
  --keep) KEEP=1 ;;
  "") ;;
  *) fail "usage: dind.sh [--keep|--down]" ;;
esac

if [ "$MODE" = down ]; then
  # A bare --down tears down whatever the last run recorded, unless the caller
  # names a run explicitly through the environment.
  if [ -z "${DVW_E2E_ROOT:-}" ] && [ -z "${DVW_E2E_PREFIX:-}" ] && [ -f "$POINTER" ]; then
    E2E_ROOT="$(cat "$POINTER")"
  fi
  PREFIX="${DVW_E2E_PREFIX:-dvw-e2e-$$}"
  E2E_ROOT="${E2E_ROOT:-${DVW_E2E_ROOT:-/tmp/$PREFIX}}"
  # shellcheck disable=SC1091
  [ -f "$E2E_ROOT/state/env" ] && . "$E2E_ROOT/state/env"
  set_names
  down
  exit 0
fi

PREFIX="${DVW_E2E_PREFIX:-dvw-e2e-$$}"
E2E_ROOT="${DVW_E2E_ROOT:-/tmp/$PREFIX}"
set_names

down 2>/dev/null || true
mkdir -p "$STATE" "$E2E_ROOT/build" "$E2E_ROOT/ws-a" "$E2E_ROOT/ws-b" "$E2E_ROOT/data"
printf 'PREFIX=%s\nE2E_ROOT=%s\n' "$PREFIX" "$E2E_ROOT" > "$STATE/env"
printf '%s\n' "$E2E_ROOT" > "$POINTER"
trap '[ $KEEP = 1 ] || down' EXIT

log "docker:dind ($DIND)"
docker network create "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
docker run -d --name "$DIND" --privileged --network "$NET" -e DOCKER_TLS_CERTDIR= \
  -v "$VOL:/var/lib/docker" docker:dind >/dev/null
DIND_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DIND")"
DIND_HOST="tcp://$DIND_IP:2375"
for _ in $(seq 1 60); do
  curl -fsS --max-time 1 "http://$DIND_IP:2375/_ping" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 2 "http://$DIND_IP:2375/_ping" >/dev/null \
  || fail "dind not reachable at $DIND_IP:2375 from this container"

log "workspace image (probe from $PROBE_SRC)"
[ -f "$PROBE_SRC" ] || fail "dvw-probe not found; set DVW_PROBE_SRC"
cp tests/e2e/workspace.Dockerfile "$E2E_ROOT/build/workspace.Dockerfile"
cp "$PROBE_SRC" "$E2E_ROOT/build/dvw-probe"
docker build -q -t "$IMG" -f "$E2E_ROOT/build/workspace.Dockerfile" "$E2E_ROOT/build" >/dev/null
docker save "$IMG" | DOCKER_HOST="$DIND_HOST" docker load >/dev/null

# The bind-mount source must exist on BOTH sides with the same path: inside
# dind (where the container mounts it) and here (where the catalog checks
# liveness with os.path.isdir). uid 1000 is the image's "dev" user, which
# needs to write the git repo into the mount. The workspace image doubles as
# the helper here: it is already inside dind, so no extra pull on a daemon
# whose image cache starts empty every run.
DOCKER_HOST="$DIND_HOST" docker run --rm --user root --entrypoint sh -v /:/host "$IMG" \
  -c "mkdir -p /host$E2E_ROOT/ws-a /host$E2E_ROOT/ws-b && chown 1000:1000 /host$E2E_ROOT/ws-a /host$E2E_ROOT/ws-b" >/dev/null
for ws in ws-a ws-b; do
  DOCKER_HOST="$DIND_HOST" docker run -d --name "$ws" --label "dev.containers.id=uid-$ws" \
    -v "$E2E_ROOT/$ws:/workspaces/$ws" "$IMG" "/workspaces/$ws" >/dev/null
done
for _ in $(seq 1 40); do
  DOCKER_HOST="$DIND_HOST" docker exec ws-b tmux has-session -t work >/dev/null 2>&1 && break
  sleep 0.5
done
DOCKER_HOST="$DIND_HOST" docker exec ws-a tmux has-session -t work \
  || fail "workspace tmux session never came up"

log "proxy"
# stdout to /dev/null and stdin from /dev/null on purpose: with --keep these
# children outlive the script, and an inherited pipe would keep a caller that
# reads our stdout (a bats run, `| tail`) waiting forever for EOF.
DVW_PROXY_LISTEN="$E2E_ROOT/proxy.sock" DVW_PROXY_UPSTREAM="$DIND_HOST" \
  /usr/bin/python3 catalog-service/proxy/dvw_docker_proxy.py \
  < /dev/null > /dev/null 2> "$STATE/proxy.log" &
echo $! >> "$STATE/pids"
for _ in $(seq 1 20); do [ -S "$E2E_ROOT/proxy.sock" ] && break; sleep 0.25; done
curl -fsS --unix-socket "$E2E_ROOT/proxy.sock" http://d/_ping >/dev/null || fail "proxy not answering"

log "catalog"
# The venv binary rather than `uv run` when it is there: uv would re-sync the
# shared venv (dropping the dev extra the pytest suites need) and would put a
# parent process between this script and the pid it has to kill at teardown.
UVICORN="$ROOT/catalog-service/.venv/bin/uvicorn"
if [ -x "$UVICORN" ]; then
  CAT_CMD=("$UVICORN")
else
  CAT_CMD=(uv run uvicorn)
fi
# `exec` inside the backgrounded subshell: the subshell becomes uvicorn, so $!
# is the pid teardown kills, and no bash is left holding this script's stdout
# (which, with --keep, would hang any caller reading it to EOF).
(
  cd catalog-service
  export CATALOG_DATA_DIR="$E2E_ROOT/data"
  export CATALOG_DOCKER_HOST="unix://$E2E_ROOT/proxy.sock"
  export CATALOG_BLUEPRINT_IMAGE_TTL=900
  exec "${CAT_CMD[@]}" app.main:app --uds "$E2E_ROOT/catalog.sock" --no-access-log
) < /dev/null > "$STATE/catalog.log" 2>&1 &
echo $! >> "$STATE/pids"
CAT="curl -fsS --unix-socket $E2E_ROOT/catalog.sock"
for _ in $(seq 1 40); do $CAT http://d/v1/health >/dev/null 2>&1 && break; sleep 0.25; done
$CAT http://d/v1/health | grep -q '"docker":true' \
  || fail "catalog cannot reach docker through the proxy: $($CAT http://d/v1/health || true)"
for ws in ws-a ws-b; do
  $CAT -X POST -H 'Content-Type: application/json' \
    -d "{\"id\":\"$ws\",\"repo\":\"git@github.com:vossiman/$ws.git\",\"branch\":\"main\"}" \
    http://d/v1/workspaces >/dev/null
done

log "assert: happy path"
status="$($CAT http://d/v1/containers/status)"
echo "$status" | python3 -c '
import json,sys; s={x["id"]:x for x in json.load(sys.stdin)}
assert s["ws-a"]["liveness"]=="alive" and s["ws-b"]["liveness"]=="alive", s
assert s["ws-a"]["container_id"], s'
windows="$($CAT http://d/v1/containers/windows)"
echo "$windows" | python3 -c '
import json,sys; w={x["workspace_id"]:x for x in json.load(sys.stdin)}
names={x["name"] for x in w["ws-a"]["windows"]}
assert {"claude","shell"} <= names, w
assert all(x["activity"]>0 for x in w["ws-a"]["windows"]), w
assert any(x["command"]=="claude" for x in w["ws-a"]["windows"]), w'
inspect="$($CAT http://d/v1/workspaces/ws-a/inspect)"
echo "$inspect" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["probe"]=="ok", d["probe"]
assert d["agents"] and d["agents"][0]["cli"]=="claude", d["agents"]
assert d["git"]["branch"]=="feat/e2e" and d["git"]["dirty"] is True, d["git"]
assert d["running"] is True, d'
grep -q 'cmd=dvw-probe' "$STATE/proxy.log" || fail "proxy never saw the probe exec"
if grep -q 'cmd=tmux' "$STATE/proxy.log"; then
  fail "catalog fell back to tmux although the probe is installed"
fi

log "assert: waiting marker after agent-notify inside the container"
DOCKER_HOST="$DIND_HOST" docker exec ws-a tmux set-option -w -t work:claude @waiting 1756795000
$CAT http://d/v1/containers/waiting | grep -q '"window_name":"claude"' || fail "waiting window not reported"

log "assert: attacks at the proxy socket are refused"
PX="curl -s -o /dev/null -w %{http_code} --unix-socket $E2E_ROOT/proxy.sock"
CID="$(echo "$status" | python3 -c 'import json,sys; print({x["id"]:x for x in json.load(sys.stdin)}["ws-a"]["container_id"])')"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Image":"alpine","HostConfig":{"Binds":["/:/host"]}}' http://d/containers/create)" = 403 ] || fail "create not refused"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Cmd":["sh"],"AttachStdout":true}' "http://d/containers/$CID/exec")" = 403 ] || fail "exec sh not refused"
[ "$($PX -X POST -H 'Content-Type: application/json' -d '{"Cmd":["dvw-probe"],"Privileged":true,"AttachStdout":true}' "http://d/containers/$CID/exec")" = 403 ] || fail "privileged exec not refused"
[ "$($PX http://d/images/json)" = 403 ] || fail "images not refused"
[ "$($PX -X POST -d '{}' http://d/exec/0000000000000000000000000000000000000000000000000000000000000000/start)" = 403 ] || fail "fabricated exec id not refused"
[ "$($PX -X DELETE "http://d/containers/$CID")" = 403 ] || fail "delete not refused"
[ "$(grep -c 'verdict=deny' "$STATE/proxy.log")" -ge 6 ] || fail "expected at least 6 deny lines in the proxy log"
DOCKER_HOST="$DIND_HOST" docker ps -a --format '{{.Names}}' | grep -qx ws-a || fail "workspace container vanished"
[ "$(DOCKER_HOST="$DIND_HOST" docker ps -aq | wc -l)" = 2 ] || fail "an attack created a container"

log "e2e ok"
if [ $KEEP = 1 ]; then
  cat <<EOF

kept running. TUI playtest:
  export DVW_TUI_SOCKET=$E2E_ROOT/catalog.sock
  export DVW_BIN=$ROOT/dvw
  uv run --project $ROOT/tui dvw-tui
  # flag a window as waiting:  DOCKER_HOST=$DIND_HOST docker exec ws-b tmux set-option -w -t work:claude @waiting \$(date +%s)
tear down with: tests/e2e/dind.sh --down
EOF
fi
