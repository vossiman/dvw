#!/usr/bin/env bats
# The devpod agent dir must actually be writable by the service.
#
# %h in a SYSTEM unit is the service manager's home (/root); User= does not
# change it. With the "-" prefix tolerating the absent dir, the unit granted
# /root/.devpod/agent and every source pull died on
# "cannot open '.git/FETCH_HEAD': Read-only file system". Observed 2026-09-09
# on dataprospectors-web, after the merge gate had already been waited on.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  UNIT="$DVW_ROOT/catalog-service/deploy/dvw-catalog.service"
  INSTALL="$DVW_ROOT/catalog-service/deploy/host-install.sh"
  UPDATE="$DVW_ROOT/catalog-service/deploy/host-update.sh"
}

@test "the unit grants a real home path, not %h" {
  grep -qE '^ReadWritePaths=-/home/vossi/\.devpod/agent$' "$UNIT"
  ! grep -qE '^ReadWritePaths=.*%h' "$UNIT"
}

@test "both installers rewrite that path for the running user" {
  grep -q 'ReadWritePaths=-/home/vossi/' "$INSTALL"
  grep -q 'ReadWritePaths=-/home/vossi/' "$UPDATE"
}

@test "render_unit rewrites the path alongside User=" {
  # Run the real sed pipeline from each installer against the real unit.
  local script
  for script in "$INSTALL" "$UPDATE"; do
    run env USER=someone RUN_GROUP=somegroup HOME=/home/someone bash -c '
      eval "$(sed -n "/^render_unit() {/,/^}/p" "$1")"
      SVC_DIR="$2"; render_unit dvw-catalog.service' _ "$script" \
      "$DVW_ROOT/catalog-service"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ReadWritePaths=-/home/someone/.devpod/agent"* ]]
    [[ "$output" == *"User=someone"* ]]
    [[ "$output" != *"/home/vossi/.devpod"* ]]
  done
}
