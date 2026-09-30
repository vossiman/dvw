#!/usr/bin/env bats
# refresh.sh vendors aicoding's selector from one resolved main commit (DVW-27).
# git and curl are stubbed, so these tests never touch the network.

setup() {
  DVW_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORK=$(mktemp -d)
  VENDOR="$WORK/vendor"
  mkdir -p "$VENDOR" "$WORK/stubs" "$WORK/upstream"
  cp "$DVW_ROOT/catalog-service/vendor/aicoding/refresh.sh" "$VENDOR/"
  SHA=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$WORK/upstream/$SHA/bin" "$WORK/upstream/$SHA/lib"
  printf 'select\n' > "$WORK/upstream/$SHA/bin/aicoding-select"
  printf 'selector\n' > "$WORK/upstream/$SHA/lib/ci-selector.sh"
  printf 'progress\n' > "$WORK/upstream/$SHA/lib/update-progress.sh"
  printf 'ui\n' > "$WORK/upstream/$SHA/lib/ui.sh"
  cat > "$WORK/stubs/git" <<STUB
#!/bin/sh
echo "git \$*" >> "$WORK/calls"
printf '%s\trefs/heads/main\n' "$SHA"
STUB
  cat > "$WORK/stubs/curl" <<STUB
#!/bin/sh
url= out=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; http*) url=\$1 ;; esac
  shift
done
echo "curl \$url" >> "$WORK/calls"
case "\$url" in *lib/update-progress.sh) [ -z "\${FAIL_PROGRESS:-}" ] || exit 22 ;; esac
cp "$WORK/upstream/\${url#https://raw.test/}" "\$out"
STUB
  chmod +x "$WORK/stubs/"*
  export PATH="$WORK/stubs:$PATH" AICODING_VENDOR_RAW_BASE=https://raw.test AICODING_VENDOR_GIT_URL=https://git.test/repo
}

teardown() { case "${WORK:-}" in /tmp/*) rm -rf "$WORK" ;; esac; }

@test "refresh fetches every file from one resolved commit and records it" {
  run bash "$VENDOR/refresh.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^git ' "$WORK/calls")" -eq 1 ]
  [ "$(grep -c "^curl https://raw.test/$SHA/" "$WORK/calls")" -eq 4 ]
  grep -qx "commit=$SHA" "$VENDOR/SOURCE"
  grep -q "  lib/ci-selector.sh$" "$VENDOR/SOURCE"
  [ -x "$VENDOR/bin/aicoding-select" ]
  cmp -s "$WORK/upstream/$SHA/lib/ci-selector.sh" "$VENDOR/lib/ci-selector.sh"
}

@test "a failed download leaves the vendored copy untouched" {
  mkdir -p "$VENDOR/lib"; printf 'old\n' > "$VENDOR/lib/ci-selector.sh"
  FAIL_PROGRESS=1 run bash "$VENDOR/refresh.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unchanged"* ]]
  [ "$(cat "$VENDOR/lib/ci-selector.sh")" = old ]
  [ ! -e "$VENDOR/SOURCE" ]
}

@test "--check passes on a match and names each drifted file" {
  bash "$VENDOR/refresh.sh" >/dev/null
  run bash "$VENDOR/refresh.sh" --check
  [ "$status" -eq 0 ]
  printf 'selector!\n' > "$WORK/upstream/$SHA/lib/ci-selector.sh"
  run bash "$VENDOR/refresh.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib/ci-selector.sh"* ]]
  [[ "$output" != *"update-progress.sh"* ]]
  [ "$(cat "$VENDOR/lib/ci-selector.sh")" = selector ]
}

# --- blueprint-preflight.sh (sourced by host-install.sh and host-update.sh) ---

_preflight() {
  # _preflight <tools...> -- <mode>: run the helper with ONLY those tools on PATH.
  local bin="$WORK/pbin" t
  rm -rf "$bin"; mkdir -p "$bin"
  while [ "$1" != -- ]; do
    printf '#!/bin/sh\nexit 0\n' > "$bin/$1"; chmod +x "$bin/$1"; shift
  done
  shift
  run env -i HOME="$WORK" PATH="$bin" /bin/bash -c \
    '. "$1"; catalog_blueprint_preflight "$2" ${3:+"$3"}' _ \
    "$DVW_ROOT/catalog-service/deploy/blueprint-preflight.sh" "$WORK/svc" "${1:-}"
}

_svc_with_selector() {
  mkdir -p "$WORK/svc/vendor/aicoding/bin"
  install -m 0755 "$DVW_ROOT/catalog-service/vendor/aicoding/bin/aicoding-select" \
    "$WORK/svc/vendor/aicoding/bin/aicoding-select"
}

@test "preflight host-tools part passes before the vendored file exists" {
  mkdir -p "$WORK/svc"
  _preflight jq timeout curl -- tools
  [ "$status" -eq 0 ]
}

@test "full preflight names the missing vendored selector" {
  mkdir -p "$WORK/svc"
  _preflight jq timeout curl --
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing vendored selector"*"vendor/aicoding/bin/aicoding-select"* ]]
}

@test "full preflight passes with the vendored selector and host tools only" {
  _svc_with_selector
  _preflight jq timeout curl --
  [ "$status" -eq 0 ]
}

@test "preflight names a missing jq" {
  _svc_with_selector
  _preflight timeout curl --
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing catalog blueprint prerequisite: jq"* ]]
}

@test "gh without curl is refused: the service has no GitHub login" {
  _svc_with_selector
  _preflight jq timeout gh --
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl"* ]]
}
