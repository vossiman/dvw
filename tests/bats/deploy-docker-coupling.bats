#!/usr/bin/env bats
# dvw-catalog must come back UP when docker.service is restarted.
#
# The unit declares Requires=docker.service, which propagates STOP but not
# START: `systemctl stop docker.service` takes dvw-catalog down with it, and
# starting docker again leaves it dead. Observed 2026-08-20 on vossisrv during
# the Docker data-root migration — the service sat inactive for 20 minutes
# after docker came back, with no error anywhere to hint at it.
#
# The fix is the reverse dependency: WantedBy=docker.service in [Install], so
# `systemctl enable` drops a symlink into docker.service.wants/ and starting
# docker pulls dvw-catalog up with it.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  UNIT="$DVW_ROOT/catalog-service/deploy/dvw-catalog.service"
}

@test "unit is WantedBy docker.service so it restarts with docker" {
  run grep -E '^WantedBy=.*\bdocker\.service\b' "$UNIT"
  [ "$status" -eq 0 ]
}

@test "unit keeps WantedBy=multi-user.target for normal boot" {
  run grep -E '^WantedBy=.*\bmulti-user\.target\b' "$UNIT"
  [ "$status" -eq 0 ]
}

@test "unit still orders itself After=docker.service" {
  run grep -E '^After=.*\bdocker\.service\b' "$UNIT"
  [ "$status" -eq 0 ]
}

# --- enablement symlinks must actually be rewritten on existing hosts ---------
#
# daemon-reload does NOT touch [Install] symlinks and `enable` only adds missing
# ones, so a changed WantedBy= silently fails to land on hosts installed before
# the change. `reenable` rewrites them.

@test "host-install.sh reenables (not just enables) the service" {
  INSTALL="$DVW_ROOT/catalog-service/deploy/host-install.sh"
  grep -qE '^\s*sudo systemctl reenable dvw-catalog\.service' "$INSTALL"
  ! grep -qE '^\s*sudo systemctl enable dvw-catalog\.service' "$INSTALL"
}

@test "host-update.sh reenables when the unit files changed" {
  grep -qE 'systemctl reenable dvw-catalog\.service' \
    "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}

@test "sudoers drop-in permits the reenable used by host-update.sh" {
  grep -qE 'NOPASSWD:.*systemctl reenable dvw-catalog\.service' \
    "$DVW_ROOT/catalog-service/deploy/host-install.sh"
}
