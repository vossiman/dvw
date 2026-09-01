#!/usr/bin/env bats
# Dry-run harness for host-install.sh's dvw-docker-proxy section (step 6/7/8).
#
# There is no systemd in CI, so this can't start real units. Instead it runs
# the REAL script end to end against a throwaway fake checkout, with
# sudo/systemctl/useradd/docker/git/uv/curl replaced by stubs on PATH. `sudo`
# never execs its argv (nothing here may touch the real /etc or /opt) — it
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
  # Record the call, and for an `install ... <dest>` archive stdin next to a
  # name derived from <dest> so tests can inspect what render_unit produced.
  cat > "$HOME/stubs/sudo" <<'SUDOEOF'
#!/bin/sh
echo "sudo $*" >> "$HOME/calls"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  /etc/*|/opt/*)
    cat > "$HOME/rendered_$(basename "$last")" 2>/dev/null
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
  run env CHECKOUT="$CHECKOUT" BRANCH=main bash "$SCRIPT"
}

@test "installer creates dvw-proxy, skips tecnativa removal when no container, and proxy healthy" {
  run_install
  [ "$status" -eq 0 ]
  grep -q 'sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups docker dvw-proxy' "$CALLS"
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

@test "sudoers drop-in covers stop/restart of both proxy units" {
  run_install
  [ "$status" -eq 0 ]
  [ -f "$HOME/rendered_dvw-catalog" ]
  grep -q 'systemctl stop dvw-docker-proxy.service' "$HOME/rendered_dvw-catalog"
  grep -q 'systemctl restart dvw-docker-proxy.socket' "$HOME/rendered_dvw-catalog"
  grep -q 'systemctl restart dvw-docker-proxy.service' "$HOME/rendered_dvw-catalog"
}

@test "both proxy units are rendered with SocketUser/User set to \$USER, like the catalog unit" {
  run_install
  [ "$status" -eq 0 ]
  [ -f "$HOME/rendered_dvw-docker-proxy.socket" ]
  [ -f "$HOME/rendered_dvw-docker-proxy.service" ]
  [ -f "$HOME/rendered_dvw-catalog.service" ]
  grep -qx "SocketUser=$USER" "$HOME/rendered_dvw-docker-proxy.socket"
  grep -qx "SocketGroup=$(id -gn)" "$HOME/rendered_dvw-docker-proxy.socket"
  grep -qx "User=$USER" "$HOME/rendered_dvw-catalog.service"
  # dvw-docker-proxy.service's User=dvw-proxy is NOT the vossi placeholder,
  # so render_unit must leave it alone.
  grep -qx 'User=dvw-proxy' "$HOME/rendered_dvw-docker-proxy.service"
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
