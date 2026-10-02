#!/usr/bin/env bats
# host-update.sh against a fake checkout with every external command stubbed
# on PATH. The catalog needs no aicoding install.

setup() {
  DVW_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORK=$(mktemp -d)
  export HOME="$WORK/home"
  mkdir -p "$HOME/stubs"
  CHECKOUT="$WORK/checkout"
  SVC_DIR="$CHECKOUT/catalog-service"
  mkdir -p "$SVC_DIR/deploy"
  cp "$DVW_ROOT"/catalog-service/deploy/*.sh "$DVW_ROOT"/catalog-service/deploy/*.service \
     "$DVW_ROOT"/catalog-service/deploy/*.socket "$DVW_ROOT"/catalog-service/deploy/*.timer \
     "$DVW_ROOT/catalog-service/deploy/gh-token-helper" "$SVC_DIR/deploy/"
  printf '#!/bin/sh\necho "configure-backup-remote $*" >> "$HOME/calls"\n' \
    > "$SVC_DIR/deploy/configure-backup-remote.sh"
  chmod +x "$SVC_DIR/deploy/configure-backup-remote.sh"
  for b in uv sudo systemctl curl; do
    printf '#!/bin/sh\necho "%s $*" >> "$HOME/calls"\nexit 0\n' "$b" > "$HOME/stubs/$b"
  done
  cat > "$HOME/stubs/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$HOME/calls"
case "$*" in *rev-parse*) echo 1111111111111111111111111111111111111111 ;; esac
exit 0
STUB
  chmod +x "$HOME/stubs/"*
  : > "$HOME/calls"
}

teardown() {
  case "${WORK:-}" in "$BATS_TEST_TMPDIR"*|/tmp/*) rm -rf "$WORK" ;; esac
}

run_update() {
  run env PATH="$HOME/stubs:/usr/bin:/bin" CHECKOUT="$CHECKOUT" \
    bash "$SVC_DIR/deploy/host-update.sh" </dev/null
}

@test "update syncs and restarts with no aicoding install" {
  run_update
  grep -qE '^uv sync' "$HOME/calls"
}

@test "update re-execs when the pull changed host-update.sh" {
  cat > "$HOME/stubs/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$HOME/calls"
case "$*" in
  *"rev-parse HEAD"*)
    if [ -e "$HOME/pulled" ]; then echo bbbbbbb; else echo aaaaaaa; fi ;;
  *"pull --ff-only"*) touch "$HOME/pulled" ;;
  *"diff --quiet"*host-update.sh*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$HOME/stubs/git"
  run_update
  [[ "$output" == *"updater changed by the pull; re-running the new copy"* ]]
}
