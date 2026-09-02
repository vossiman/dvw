#!/usr/bin/env bats
# host-install.sh must RESTART the service, not just `enable --now`.
#
# `enable --now` starts an inactive unit but leaves a running one alone. So
# re-running the installer against a live service updated the checkout and venv
# while the old code kept serving — and the installer's smoke test still passed,
# because /v1/health exists in every build. Observed 2026-07-26.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  INSTALL="$DVW_ROOT/catalog-service/deploy/host-install.sh"
}

@test "host-install.sh restarts dvw-catalog.service" {
  grep -qE '^\s*sudo systemctl restart dvw-catalog\.service' "$INSTALL"
}

@test "host-install.sh does not rely on 'enable --now' for the service" {
  # The timer may still use --now; the SERVICE must not.
  ! grep -qE '^\s*sudo systemctl enable --now dvw-catalog\.service' "$INSTALL"
}

@test "host-update.sh also restarts (the documented update path)" {
  grep -qE 'systemctl restart dvw-catalog\.service' \
    "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}

@test "deploy scripts never block on a git credential prompt" {
  # A GitHub 401 makes git ask for a username unless prompting is off; with
  # the prompt, the git_retry loop never gets its second attempt.
  grep -qE '^export GIT_TERMINAL_PROMPT=0' "$INSTALL"
  grep -qE '^export GIT_TERMINAL_PROMPT=0' "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}
