#!/usr/bin/env bats
# dvw-catalog-backup.service: the Kuma heartbeat is sent only after a
# successful `git push`, and never when CATALOG_BACKUP_PUSH_URL is unset. No
# systemd in CI, so the test extracts the unit's push ExecStart line and runs
# it under /bin/sh with git and curl stubbed on PATH, after applying the same
# ${VAR} expansion systemd would.

setup() {
  DVW_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  UNIT="$DVW_ROOT/catalog-service/deploy/dvw-catalog-backup.service"
  WORK=$(mktemp -d)
  export HOME="$WORK"
  mkdir -p "$WORK/stubs"
  cat > "$WORK/stubs/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$HOME/calls"
[ -e "$HOME/push-fails" ] && exit 1
exit 0
STUB
  cat > "$WORK/stubs/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$HOME/calls"
exit 0
STUB
  chmod +x "$WORK/stubs/"*
  export PATH="$WORK/stubs:$PATH"
  # Never run from a checkout: if the stub were bypassed, a real git push
  # from here would find no repository.
  mkdir -p "$WORK/cwd"; cd "$WORK/cwd"
}
teardown() { rm -rf "$WORK"; }

# run_push_step [URL]: the unit's push line, with systemd's ${VAR} expansion
# applied for CATALOG_BACKUP_PUSH_URL, executed by /bin/sh.
run_push_step() {
  local line cmd
  line="$(grep '^ExecStart=.*git push' "$UNIT")"
  [ -n "$line" ]
  cmd="${line#ExecStart=}"; cmd="${cmd#-}"
  cmd="${cmd//\$\{CATALOG_BACKUP_PUSH_URL\}/${1:-}}"
  case "$cmd" in "/bin/sh -c '"*"'") ;; *) echo "push line is not a /bin/sh -c '...' command: $cmd" >&2; return 1 ;; esac
  cmd="${cmd#/bin/sh -c }"
  cmd="${cmd#\'}"; cmd="${cmd%\'}"
  sh -c "$cmd"
}

@test "unit reads the catalog env file and does not hard-fail without it" {
  grep -q '^EnvironmentFile=-/opt/dvw-catalog/catalog.env$' "$UNIT"
}

@test "successful push sends the heartbeat to the configured URL" {
  run_push_step 'https://uptime.example/api/push/TOK?status=up&msg=OK&ping='
  grep -q '^git push' "$HOME/calls"
  grep -q 'curl .*https://uptime.example/api/push/TOK' "$HOME/calls"
}

@test "failed push sends no heartbeat and does not fail the unit" {
  touch "$HOME/push-fails"
  run run_push_step 'https://uptime.example/api/push/TOK'
  [ "$status" -eq 0 ]
  grep -q '^git push' "$HOME/calls"
  if grep -q '^curl' "$HOME/calls"; then false; fi
}

@test "no push URL configured: push happens, no curl" {
  run_push_step
  grep -q '^git push' "$HOME/calls"
  if grep -q '^curl' "$HOME/calls"; then false; fi
}

@test "catalog.env.example documents the variable" {
  grep -q '^#CATALOG_BACKUP_PUSH_URL=' "$DVW_ROOT/catalog-service/deploy/catalog.env.example"
}
