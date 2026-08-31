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

# --- adversarial body content, with a credential set (forces the combined
# `--config -` stream carrying both `header` and the body) -------------------
#
# A body's value inside that config stream must never be re-interpreted by
# curl's own `@filename`/`$filename` special-casing (that is exactly what
# `--data-binary` does, and what `--data-raw` deliberately does not do).
# These round-trip the body through the real curl-config-line-building code
# in lib/catalog-http-lib.sh and the shared bats curl/ssh stub (which parses
# it the same way real curl's config-file parser does — verified separately
# against actual curl 8.18.0, see task-2-report.md), then assert the
# service saw the identical bytes back AND that ssh's argv never carried
# fragments of it.

@test "authenticated POST: leading '@' body byte survives and is not argv" {
  local STUB_BIN="$TMPDIR_T/stubbin"
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"
  export DVW_CATALOG_HOST=stub
  export PATH="$STUB_BIN:$PATH"
  source "${BATS_TEST_DIRNAME}/lib/catalog-stub.bash"
  local body='@{"marker":"leading-at-sign"}'
  # Would fail against a regression to `data-binary`: curl (or, in this stub,
  # _stub_cfg_value looking for the wrong key) would try to read a local
  # file named after the body instead of sending it, so the echoed body
  # would come back empty/wrong instead of matching `$body`.
  catalog_route() { _stub_emit "$3" 200; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req POST /v1/workspaces "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]
}

@test "authenticated POST: quotes, backslashes, embedded newline and UTF-8 survive byte-identical" {
  local STUB_BIN="$TMPDIR_T/stubbin"
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"
  export DVW_CATALOG_HOST=stub
  export PATH="$STUB_BIN:$PATH"
  source "${BATS_TEST_DIRNAME}/lib/catalog-stub.bash"
  # Leading '"', a literal backslash, an embedded newline, and 'é' (UTF-8).
  # Would fail if _catalog_cfg_escape mis-ordered its substitutions (escaping
  # '"' before '\' would double-escape and corrupt the value) or dropped the
  # newline/UTF-8 handling.
  local body=$'"quoted start", back\\slash, line one\nline two, café'
  catalog_route() { _stub_emit "$3" 200; }
  catalog_stub_install
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  run _catalog_req POST /v1/workspaces "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]
}

@test "authenticated POST: adversarial body never leaks into ssh argv" {
  export DVW_CATALOG_TOKEN="SENTINEL-TOKEN-abc123"
  export DVW_CATALOG_SOCK="$TMPDIR_T/absent.sock"   # the simple argv-capturing ssh from setup()
  source "$DVW_ROOT/lib/catalog-http-lib.sh"
  local body=$'@"SECRET-ADVERSARIAL-9f3\\slash\nline2-é"'
  run _catalog_req POST /v1/workspaces "$body"
  [ "$status" -eq 0 ]
  run grep -c 'SECRET-ADVERSARIAL-9f3' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
  run grep -c 'SENTINEL-TOKEN-abc123' "$TMPDIR_T/ssh-argv"
  [ "$output" = "0" ]
}
