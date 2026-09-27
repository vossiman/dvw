#!/usr/bin/env bats
# host-update.sh checks the same blueprint selector prerequisite as
# host-install.sh before it changes the host (DVW-26). Runs the real script
# against a fake checkout with every external command stubbed on PATH.

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
  mkdir -p "$SVC_DIR/vendor/aicoding/bin"
  install -m 0755 "$DVW_ROOT/catalog-service/vendor/aicoding/bin/aicoding-select" \
    "$SVC_DIR/vendor/aicoding/bin/aicoding-select"
  for b in uv sudo systemctl jq timeout curl; do
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

@test "update refuses a missing vendored selector before sync, backup config or restart" {
  rm -f "$SVC_DIR/vendor/aicoding/bin/aicoding-select"
  run_update
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing vendored selector"* ]]
  ! grep -qE '^(uv|sudo|systemctl|configure-backup-remote) ' "$HOME/calls"
}

@test "update refuses a mutable blueprint URL in catalog.env" {
  printf 'CATALOG_BLUEPRINT_DEVCONTAINER_URL=https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/devcontainer.json\n' \
    > "$SVC_DIR/catalog.env"
  run_update
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an exact supported immutable URL"* ]]
  ! grep -qE '^(uv|sudo) ' "$HOME/calls"
}

@test "an exported URL cannot satisfy the update check for the service" {
  rm -f "$SVC_DIR/vendor/aicoding/bin/aicoding-select"
  export CATALOG_BLUEPRINT_DEVCONTAINER_URL="https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/abcdefabcdefabcdefabcdefabcdefabcdefabcd/devcontainer.json"
  run_update
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing vendored selector"* ]]
}

@test "immutable URL in catalog.env passes without the selector" {
  rm -f "$SVC_DIR/vendor/aicoding/bin/aicoding-select"
  printf 'CATALOG_BLUEPRINT_DEVCONTAINER_URL=https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/1234567890abcdef1234567890abcdef12345678/devcontainer.json\n' \
    > "$SVC_DIR/catalog.env"
  run_update
  [[ "$output" != *"blueprint prerequisite"* ]]
  grep -qE '^uv sync' "$HOME/calls"
}

@test "the vendored selector passes the update check with no aicoding install" {
  run_update
  [[ "$output" != *"blueprint prerequisite"* ]]
  grep -qE '^uv sync' "$HOME/calls"
}

@test "update re-execs when the pull changed only blueprint-preflight.sh" {
  cat > "$HOME/stubs/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$HOME/calls"
case "$*" in
  *"rev-parse HEAD"*)
    if [ -e "$HOME/pulled" ]; then echo bbbbbbb; else echo aaaaaaa; fi ;;
  *"pull --ff-only"*) touch "$HOME/pulled" ;;
  *"diff --quiet"*blueprint-preflight.sh*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$HOME/stubs/git"
  run_update
  [[ "$output" == *"updater changed by the pull; re-running the new copy"* ]]
}
