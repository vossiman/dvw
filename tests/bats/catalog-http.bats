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

@test "authenticated POST: neither the credential nor the body appears in ssh argv" {
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"   # force the ssh branch
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req POST /v1/workspaces '{"marker":"SECRET-BODY-xyz789","n":1}'
  [ "$status" -eq 0 ]
  run grep -c 'SENTINEL-TOKEN-abc123' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
  run grep -c 'SECRET-BODY-xyz789' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
}

@test "authenticated POST: no temp file is created on either host" {
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"   # force the ssh branch
  # Fake ssh that also snapshots what showed up under TMPDIR while the
  # "remote" command ran, so a bodyfile written on the remote side (there is
  # none in this design, but a regression could reintroduce one) would show
  # up here just like a local one would.
  cat >"$TMPDIR_T/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMPDIR_T/ssh-argv"
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'dvw-cat-body.*' 2>/dev/null >>"$TMPDIR_T/tmp-snapshot"
printf 'body\n200\n'
EOF
  chmod +x "$TMPDIR_T/ssh"
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req POST /v1/workspaces '{"marker":"SECRET-BODY-xyz789"}'
  [ "$status" -eq 0 ]
  [ ! -s "$TMPDIR_T/tmp-snapshot" ]
  run bash -c "compgen -G '${TMPDIR:-/tmp}/dvw-cat-body.*'"
  [ "$status" -ne 0 ]
}
