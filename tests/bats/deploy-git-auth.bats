#!/usr/bin/env bats
# The deploy scripts authenticate git through gh-token-helper, which reads
# the GitHub token from the estate's shared secrets store on the host. These
# tests use a fake store with a fake value; nothing real is read.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="$DVW_ROOT/catalog-service/deploy/gh-token-helper"
  UPDATE="$DVW_ROOT/catalog-service/deploy/host-update.sh"
  INSTALL="$DVW_ROOT/catalog-service/deploy/host-install.sh"
  FAKE_STORE="$BATS_TEST_TMPDIR/store.env"
  printf 'OTHER=1\nGH_TOKEN="ghp_fake_for_tests"\nMORE=2\n' > "$FAKE_STORE"
}

@test "helper answers get for github.com with the token from the store" {
  run env DVW_SECRETS_FILE="$FAKE_STORE" bash "$HELPER" get <<< $'protocol=https\nhost=github.com\n'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "username=x-access-token" ]
  [ "${lines[1]}" = "password=ghp_fake_for_tests" ]
}

@test "helper stays silent for other hosts" {
  run env DVW_SECRETS_FILE="$FAKE_STORE" bash "$HELPER" get <<< $'protocol=https\nhost=gitlab.com\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helper stays silent when the store is missing or has no token" {
  run env DVW_SECRETS_FILE="$BATS_TEST_TMPDIR/nope" bash "$HELPER" get <<< $'host=github.com\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'OTHER=1\n' > "$FAKE_STORE"
  run env DVW_SECRETS_FILE="$FAKE_STORE" bash "$HELPER" get <<< $'host=github.com\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helper never stores or erases anything" {
  run env DVW_SECRETS_FILE="$FAKE_STORE" bash "$HELPER" store <<< $'host=github.com\npassword=x\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env DVW_SECRETS_FILE="$FAKE_STORE" bash "$HELPER" erase <<< $'host=github.com\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helper is executable and its shebang runs under bash" {
  [ -x "$HELPER" ]
  head -n 1 "$HELPER" | grep -q bash
}

@test "every network git call in the deploy scripts goes through git_auth" {
  # pull/fetch/clone are the calls that reach GitHub; local rev-parse,
  # config, checkout and diff stay plain git.
  if grep -nE '^\s*git_retry git -C' "$UPDATE" "$INSTALL"; then false; fi
  if grep -nE '^\s*git_retry git -c' "$INSTALL"; then false; fi
  grep -qE '^\s*git_retry git_auth -C "\$CHECKOUT" pull --ff-only' "$UPDATE"
  grep -qE '^\s*git_retry git_auth -C "\$CHECKOUT" fetch origin' "$INSTALL"
  grep -qE '^\s*git_retry git_auth -c protocol.version=1 clone' "$INSTALL"
}

@test "git_auth disables any other configured helper before adding ours" {
  grep -qE 'credential.helper= -c "credential.helper=\$GH_HELPER"' "$UPDATE"
  grep -qE 'credential.helper= -c "credential.helper=\$GH_HELPER"' "$INSTALL"
}
