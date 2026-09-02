#!/usr/bin/env bats
# Dry-run harness for host-install.sh's dvw-docker-proxy section (step 6/7/8).
#
# There is no systemd in CI, so this can't start real units. Instead it runs
# the REAL script end to end against a throwaway fake checkout, with
# sudo/systemctl/useradd/docker/git/uv/curl replaced by stubs on PATH. `sudo`
# never execs its argv: nothing here may touch the real /etc or /opt. It
# just records the call and, for an `install ... <dest>` invocation, archives
# whatever was piped to its stdin under a name derived from <dest> so tests
# can inspect the rendered unit content. This pins two things: the exact
# command sequence (stop-then-restart-socket, sudoers scope, ordering
# relative to the catalog restart) and that SocketUser/SocketGroup get
# rendered to $USER/$GROUP the same way User=/Group= do.

setup() {
  DVW_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$DVW_ROOT/catalog-service/deploy/host-install.sh"

  WORK=$(mktemp -d)
  export HOME="$WORK/home"
  mkdir -p "$HOME/stubs"

  # --- fake checkout: just enough for the script to walk through steps 1-8 ---
  CHECKOUT="$WORK/checkout"
  SVC_DIR="$CHECKOUT/catalog-service"
  mkdir -p "$SVC_DIR/deploy" "$CHECKOUT/.git"
  cp "$DVW_ROOT/catalog-service/deploy/dvw-catalog.service" \
     "$DVW_ROOT/catalog-service/deploy/dvw-catalog-backup.service" \
     "$DVW_ROOT/catalog-service/deploy/dvw-catalog-backup.timer" \
     "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.socket" \
     "$DVW_ROOT/catalog-service/deploy/dvw-docker-proxy.service" \
     "$DVW_ROOT/catalog-service/deploy/catalog.env.example" \
     "$SVC_DIR/deploy/"

  # --- stubs ---
  # git/uv: no-op success, so the checkout-refresh and venv-sync steps never
  # touch the network or need a real project.
  for b in git uv; do
    printf '#!/bin/sh\necho "%s $*" >> "$HOME/calls"\nexit 0\n' "$b" > "$HOME/stubs/$b"
  done
  # docker: no containers, so the tecnativa-retirement branch is exercised
  # (command -v docker succeeds) but finds nothing to remove.
  cat > "$HOME/stubs/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$HOME/calls"
case "$1 $2" in
  "ps -a") : ;;  # print nothing: no matching container
esac
exit 0
EOF
  # curl: succeed immediately for both the proxy _ping poll and the catalog
  # /v1/health smoke test, so neither retry loop actually sleeps.
  cat > "$HOME/stubs/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$HOME/calls"
case "$*" in
  *v1/health*) printf '{"ok":true}' ;;
esac
exit 0
EOF
  # sudo: NEVER execs its argv (this must not touch the real /etc or /opt).
  # Record the call, and for an `install ... <dest>` archive stdin under a
  # name derived from the FULL destination path (slashes turned into
  # underscores, not just the basename) so two destinations that happen to
  # share a basename can never collide, and tests can inspect what
  # render_unit produced.
  cat > "$HOME/stubs/sudo" <<'SUDOEOF'
#!/bin/sh
echo "sudo $*" >> "$HOME/calls"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  /etc/*|/opt/*)
    key=$(echo "$last" | sed 's#^/##; s#/#_#g')
    cat > "$HOME/rendered_$key" 2>/dev/null
    ;;
  *)
    cat >/dev/null 2>&1
    ;;
esac
exit 0
SUDOEOF
  chmod +x "$HOME/stubs/"*

  export PATH="$HOME/stubs:/usr/bin:/bin"
  export CHECKOUT BRANCH=main
  export CALLS="$HOME/calls"
  : > "$CALLS"
}

teardown() {
  case "${WORK:-}" in "$BATS_TEST_TMPDIR"*|/tmp/*) rm -rf "$WORK" ;; esac
}

run_install() {
  # </dev/null: bats' own stdin must never reach the script, so a stub that
  # ever fell through to reading stdin (e.g. a future `sudo -v` change) fails
  # fast instead of hanging the test.
  run env CHECKOUT="$CHECKOUT" BRANCH=main bash "$SCRIPT" </dev/null
}

@test "installer creates dvw-proxy, skips tecnativa removal when no container, and proxy healthy" {
  run_install
  [ "$status" -eq 0 ]
  grep -q 'sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group --groups docker dvw-proxy' "$CALLS"
  grep -q 'docker rm -f deploy-docker-proxy-1' "$CALLS" && { echo "should not remove a container that was never listed" >&2; return 1; }
  echo "$output" | grep -q '==> proxy healthy'
}

@test "restart sequence is stop-service-then-restart-socket, before the catalog restart" {
  run_install
  [ "$status" -eq 0 ]
  # Every line mentioning the proxy service/socket, in call order.
  grep -nE 'sudo (systemctl (stop|restart|reenable) dvw-docker-proxy|systemctl restart dvw-catalog\.service)' "$CALLS" > "$WORK/seq"
  cat "$WORK/seq"
  # stop dvw-docker-proxy.service must appear, and strictly before the
  # restart of dvw-docker-proxy.socket that follows it.
  stop_line=$(grep -n 'systemctl stop dvw-docker-proxy.service' "$WORK/seq" | head -1 | cut -d: -f1)
  sock_line=$(grep -n 'systemctl restart dvw-docker-proxy.socket' "$WORK/seq" | head -1 | cut -d: -f1)
  catalog_line=$(grep -n 'systemctl restart dvw-catalog.service' "$WORK/seq" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ]
  [ -n "$sock_line" ]
  [ -n "$catalog_line" ]
  [ "$stop_line" -lt "$sock_line" ]
  [ "$sock_line" -lt "$catalog_line" ]
}

@test "sudoers drop-in covers stop/restart/reenable of both proxy units" {
  run_install
  [ "$status" -eq 0 ]
  SUDOERS="$HOME/rendered_etc_sudoers.d_dvw-catalog"
  [ -f "$SUDOERS" ]
  grep -q 'systemctl stop dvw-docker-proxy.service' "$SUDOERS"
  grep -q 'systemctl restart dvw-docker-proxy.socket' "$SUDOERS"
  grep -q 'systemctl restart dvw-docker-proxy.service' "$SUDOERS"
  grep -q 'systemctl reenable dvw-docker-proxy.socket' "$SUDOERS"
}

@test "both proxy units are rendered with SocketUser/User set to \$USER, like the catalog unit" {
  run_install
  [ "$status" -eq 0 ]
  SOCK_UNIT="$HOME/rendered_etc_systemd_system_dvw-docker-proxy.socket"
  SVC_UNIT="$HOME/rendered_etc_systemd_system_dvw-docker-proxy.service"
  CATALOG_UNIT="$HOME/rendered_etc_systemd_system_dvw-catalog.service"
  [ -f "$SOCK_UNIT" ]
  [ -f "$SVC_UNIT" ]
  [ -f "$CATALOG_UNIT" ]
  grep -qx "SocketUser=$USER" "$SOCK_UNIT"
  grep -qx "SocketGroup=$(id -gn)" "$SOCK_UNIT"
  grep -qx "User=$USER" "$CATALOG_UNIT"
  # dvw-docker-proxy.service's User=dvw-proxy is NOT the vossi placeholder,
  # so render_unit must leave it alone.
  grep -qx 'User=dvw-proxy' "$SVC_UNIT"
}

@test "dvw-proxy user is created with --user-group (not relying on USERGROUPS_ENAB)" {
  run_install
  [ "$status" -eq 0 ]
  grep -q -- '--user-group' "$CALLS"
  grep -q 'sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group --groups docker dvw-proxy' "$CALLS"
}

@test "host-update.sh reenables dvw-docker-proxy.socket when it changed, like the catalog unit" {
  UPDATE="$DVW_ROOT/catalog-service/deploy/host-update.sh"
  grep -q 'systemctl reenable dvw-docker-proxy.socket' "$UPDATE"
}

@test "host-update restarts the socket even when the service stop fails" {
  UPDATE="$DVW_ROOT/catalog-service/deploy/host-update.sh"
  # git: pull succeeds; `diff --quiet ... catalog-service/proxy` reports a
  # change (exit 1), which is the branch that restarts the proxy.
  cat > "$HOME/stubs/git" <<'EOF'
#!/bin/sh
echo "git $*" >> "$HOME/calls"
case "$*" in
  *"diff --quiet"*) exit 1 ;;
esac
exit 0
EOF
  # sudo: as in setup(), but the proxy stop FAILS. The socket restart must
  # still run, and the failure must surface as the WARN.
  cat > "$HOME/stubs/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$HOME/calls"
case "$*" in
  *"systemctl stop dvw-docker-proxy.service"*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$HOME/stubs/git" "$HOME/stubs/sudo"
  run env CHECKOUT="$CHECKOUT" bash "$UPDATE" </dev/null
  # The run ends at the smoke test, which needs a real /run socket. Everything
  # under test happens before that, and pinning the reason keeps an earlier
  # breakage from passing as this expected stop.
  echo "$output" | grep -q 'smoke test FAILED: /run/dvw-docker-proxy/docker.sock is missing'
  grep -nE 'sudo -n systemctl (stop dvw-docker-proxy\.service|restart dvw-docker-proxy\.socket)' \
    "$CALLS" > "$WORK/useq"
  cat "$WORK/useq"
  stop_line=$(grep -n 'systemctl stop dvw-docker-proxy.service' "$WORK/useq" | head -1 | cut -d: -f1)
  sock_line=$(grep -n 'systemctl restart dvw-docker-proxy.socket' "$WORK/useq" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ]
  [ -n "$sock_line" ]
  [ "$stop_line" -lt "$sock_line" ]
  echo "$output" | grep -q 'WARN: proxy code changed but could not restart'
}

@test "an existing tcp:// CATALOG_DOCKER_HOST is migrated to the proxy socket" {
  install -m 0640 "$SVC_DIR/deploy/catalog.env.example" "$SVC_DIR/catalog.env"
  sed -i 's|^CATALOG_DOCKER_HOST=.*|CATALOG_DOCKER_HOST=tcp://127.0.0.1:2375|' "$SVC_DIR/catalog.env"
  run_install
  [ "$status" -eq 0 ]
  grep -qx 'CATALOG_DOCKER_HOST=unix:///run/dvw-docker-proxy/docker.sock' "$SVC_DIR/catalog.env"
}

@test "a running tecnativa container is removed by name" {
  cat > "$HOME/stubs/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$HOME/calls"
case "$1 $2" in
  "ps -a") echo "deploy-docker-proxy-1" ;;
esac
exit 0
EOF
  chmod +x "$HOME/stubs/docker"
  run_install
  [ "$status" -eq 0 ]
  grep -q 'docker rm -f deploy-docker-proxy-1' "$CALLS"
}

@test "an empty CATALOG_DOCKER_HOST is rewritten to the proxy socket" {
  # config.py refuses an empty value, so "leave any other value alone" must
  # not extend to a key that is present but blank.
  install -m 0640 "$SVC_DIR/deploy/catalog.env.example" "$SVC_DIR/catalog.env"
  sed -i 's|^CATALOG_DOCKER_HOST=.*|CATALOG_DOCKER_HOST=|' "$SVC_DIR/catalog.env"
  run_install
  [ "$status" -eq 0 ]
  grep -qx 'CATALOG_DOCKER_HOST=unix:///run/dvw-docker-proxy/docker.sock' "$SVC_DIR/catalog.env"
}

@test "an unreachable docker warns instead of silently skipping the tecnativa retirement" {
  # The installing user may already be out of the docker group, which is the
  # end state this migration wants. Then `docker ps` fails, and "no container"
  # is not a conclusion the installer may draw.
  cat > "$HOME/stubs/docker" <<'EOF2'
#!/bin/sh
echo "docker $*" >> "$HOME/calls"
echo "permission denied while trying to connect to the Docker daemon socket" >&2
exit 1
EOF2
  chmod +x "$HOME/stubs/docker"
  run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: docker is installed but not reachable'
  if grep -q 'docker rm -f deploy-docker-proxy-1' "$CALLS"; then
    echo "must not claim to remove what it could not see" >&2
    return 1
  fi
  echo "$output" | grep -q 'sudo docker rm -f deploy-docker-proxy-1' 
}

@test "a leftover 127.0.0.1:2375 listener warns but does not fail the install" {
  cat > "$HOME/stubs/ss" <<'EOF2'
#!/bin/sh
echo "ss $*" >> "$HOME/calls"
echo "LISTEN 0      4096       127.0.0.1:2375       0.0.0.0:*"
EOF2
  chmod +x "$HOME/stubs/ss"
  run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: something still listens on 127.0.0.1:2375'
}

@test "no 2375 listener means no leftover-proxy warning" {
  cat > "$HOME/stubs/ss" <<'EOF2'
#!/bin/sh
echo "ss $*" >> "$HOME/calls"
echo "LISTEN 0      4096         0.0.0.0:22          0.0.0.0:*"
EOF2
  chmod +x "$HOME/stubs/ss"
  run_install
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q '127.0.0.1:2375'; then
    echo "should not warn without a listener" >&2
    return 1
  fi
  echo "$output" | grep -q '==> proxy healthy'
}
