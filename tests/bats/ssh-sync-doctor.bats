#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export DVW_CATALOG_HOST="catalog-host"
  mkdir -p "$HOME/.ssh"
  printf 'Host *.devpod\n' > "$HOME/.ssh/dvw.conf"
  chmod 600 "$HOME/.ssh/dvw.conf"
  printf 'Include "dvw.conf"\n' > "$HOME/.ssh/config"

  ui_status_ok() { printf 'OK: %s\n' "$*"; }
  ui_status_warn() { printf 'WARN: %s\n' "$*"; }
  export -f ui_status_ok ui_status_warn

  source "$DVW_ROOT/lib/ssh-sync.sh"
}

teardown() { rm -rf "$TMPDIR"; }

@test "doctor reports managed SSH defaults version and migration state" {
  _catalog_req() {
    printf '%s\n' \
      '{"content":"ignored","managed_version":2,"migration_status":"managed_upgraded"}'
  }

  run ssh_sync_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"managed defaults v2; managed_upgraded"* ]]
  [[ "$output" == *"ssh local copy:"* ]]
  [[ "$output" == *"ssh include:"* ]]
}

@test "doctor remains compatible with an older catalog response" {
  _catalog_req() { printf '%s\n' '{"content":"legacy","version":1}'; }

  run ssh_sync_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"service://catalog-host/v1/blueprint)"* ]]
  [[ "$output" != *"managed defaults v"* ]]
}
