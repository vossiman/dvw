#!/usr/bin/env bats

setup() {
  DVW_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export DVW_ROOT
  TMPDIR_T="$(mktemp -d)"
  export TMPDIR_T PATH="$TMPDIR_T:$PATH"
  # Fake ssh that records the exact argv it was handed.
  cat >"$TMPDIR_T/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMPDIR_T/ssh-argv"
printf 'body\n200\n'
EOF
  chmod +x "$TMPDIR_T/ssh"
}

teardown() { rm -rf "$TMPDIR_T"; }

@test "bearer credential never appears in the ssh argv" {
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"   # force the ssh branch
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req GET /v1/health
  [ "$status" -eq 0 ]
  run grep -c 'SENTINEL-TOKEN-abc123' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
}

@test "unauthenticated path still works and sends no auth header" {
  unset DVW_CATALOG_TOKEN
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req GET /v1/health
  [ "$status" -eq 0 ]
  run grep -c 'authorization' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
}
