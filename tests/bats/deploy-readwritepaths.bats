#!/usr/bin/env bats
# Home paths the service writes must be real paths for the running user.
#
# %h in a SYSTEM unit is the service manager's home (/root); User= does not
# change it. With the "-" prefix tolerating an absent dir, a %h grant silently
# points at /root and the write fails read-only. Observed 2026-09-09 with the
# (since removed) devpod agent dir grant.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  UNIT="$DVW_ROOT/catalog-service/deploy/dvw-catalog.service"
  INSTALL="$DVW_ROOT/catalog-service/deploy/host-install.sh"
  UPDATE="$DVW_ROOT/catalog-service/deploy/host-update.sh"
}

@test "the unit grants real home paths, not %h, and no devpod agent dir" {
  ! grep -qE '^ReadWritePaths=.*%h' "$UNIT"
  ! grep -qE '^ReadWritePaths=.*\.devpod' "$UNIT"
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
    [[ "$output" == *"User=someone"* ]]
    [[ "$output" != *"/home/vossi/"* ]]
  done
}

@test "rendered catalog service can execute the minimal user-local CI selector" {
  local script
  for script in "$INSTALL" "$UPDATE"; do
    run env USER=someone RUN_GROUP=somegroup HOME=/home/someone bash -c '
      eval "$(sed -n "/^render_unit() {/,/^}/p" "$1")"
      SVC_DIR="$2"; render_unit dvw-catalog.service' _ "$script" \
      "$DVW_ROOT/catalog-service"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Environment=PATH=/home/someone/.local/bin:"* ]]
    [[ "$output" != *"Environment=PATH=/home/vossi/.local/bin:"* ]]
  done
}

@test "the unit grants the fleet proof dir and not its parent" {
  grep -qxF 'ReadWritePaths=-/home/vossi/devpod/aicodingsetup/fleet' "$UNIT"
  ! grep -qE '^ReadWritePaths=-?/home/vossi/devpod/aicodingsetup/?$' "$UNIT"
}

@test "render_unit rewrites the fleet path for the running user" {
  local script
  for script in "$INSTALL" "$UPDATE"; do
    run env USER=someone RUN_GROUP=somegroup HOME=/home/someone bash -c '
      eval "$(sed -n "/^render_unit() {/,/^}/p" "$1")"
      SVC_DIR="$2"; render_unit dvw-catalog.service' _ "$script" \
      "$DVW_ROOT/catalog-service"
    [[ "$output" == *"ReadWritePaths=-/home/someone/devpod/aicodingsetup/fleet"* ]]
  done
}

@test "both installers create the fleet dir only under an existing aicodingsetup" {
  grep -q 'if \[ -d "\$HOME/devpod/aicodingsetup" \]; then' "$INSTALL"
  grep -q 'install -d -m 0755 "\$HOME/devpod/aicodingsetup/fleet"' "$INSTALL"
  grep -q 'install -d -m 0755 "\$HOME/devpod/aicodingsetup/fleet"' "$UPDATE"
}
