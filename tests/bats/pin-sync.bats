#!/usr/bin/env bats
#
# `dvw pin-sync` and the rebuild pre-flight.
#
# Context: aicoding-sync rewrites .devcontainer/devcontainer.json in the
# container working tree but never commits it, so repo copies drift and
# `devpod up --recreate` (which builds from the COMMITTED pin) reinstalls the
# stale image. These tests pin the classification and the offer-before-rebuild
# behavior. All GitHub/network access is stubbed — no gh, no curl.

setup() {
  # Plain source on purpose — see the note in dispatch.bats about set +o and
  # bats' ERR trap.
  source "$DVW_ROOT/dvw"

  ui_progress() { shift; "$@"; }
  dvw_update_refresh_if_stale() { :; }
  dvw_update_maybe_nudge() { :; }
  catalog_init_if_missing() { :; }
  ssh_sync_refresh() { :; }
  wsl_bridge_refresh() { :; }

  BP_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'a%.0s' {1..64})"
  OLD_IMAGE="ghcr.io/vossiman/devbox-base@sha256:$(printf 'b%.0s' {1..64})"
  export BP_IMAGE OLD_IMAGE

  _dvw_blueprint_pin() { printf '%s\n' "$BP_IMAGE"; }
  catalog_workspace_get() {
    jq -n --arg r "git@github.com:vossiman/demo.git" --arg b main \
      '{repo:$r, branch:$b, ide:"ssh"}'
  }
  catalog_workspace_ids() { printf 'demo\n'; }
  command() { builtin command "$@"; }   # real lookups unless overridden below
}

@test "pin state: repo pin equal to the blueprint is ok" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == ok$'\t'vossiman/demo$'\t'main* ]]
}

@test "pin state: an older digest is stale" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == stale$'\t'vossiman/demo$'\t'main* ]]
}

@test "pin state: a repo with no devcontainer image is 'none', not stale" {
  _dvw_repo_pin() { printf '\n'; }
  run _dvw_pin_state demo
  [ "$status" -eq 0 ]
  [[ "$output" == none$'\t'* ]]
}

# review 2026-08-21: any gh failure used to `return 0`, classifying transient
# network/auth errors as "unpinned" and silently passing preflight.
@test "repo pin lookup: a transient gh failure is unknown (rc 1), not none" {
  gh() { echo "gh: error (HTTP 502)" >&2; return 1; }
  run _dvw_repo_pin vossiman/demo main
  [ "$status" -ne 0 ]
}

@test "repo pin lookup: HTTP 404 stays 'none' (rc 0, empty output)" {
  gh() { echo "gh: Not Found (HTTP 404)" >&2; return 1; }
  run _dvw_repo_pin vossiman/demo main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repo slug: both remote forms the fleet uses resolve to owner/name" {
  run _dvw_repo_slug "git@github.com:vossiman/demo.git"
  [ "$output" = "vossiman/demo" ]
  run _dvw_repo_slug "https://github.com/vossiman/demo"
  [ "$output" = "vossiman/demo" ]
}

@test "repo slug: a non-GitHub remote is refused (the gh PR path can't serve it)" {
  run _dvw_repo_slug "https://gitlab.com/vossiman/demo.git"
  [ "$status" -ne 0 ]
}

@test "pin-sync: a stale workspace gets a PR opened" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  _dvw_pin_open_pr() { printf 'https://github.com/%s/pull/1\n' "$1"; }
  run cmd_pin_sync demo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "stale"
  echo "$output" | grep -q "https://github.com/vossiman/demo/pull/1"
}

@test "pin-sync: a current workspace opens nothing" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  _dvw_pin_open_pr() { echo "SHOULD NOT RUN"; return 1; }
  run cmd_pin_sync demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT RUN"
  echo "$output" | grep -q "already at"
}

# review 2026-08-21: every PR failing still returned 0, so automation saw a
# healthy run while nothing was synced.
@test "pin-sync: a failed PR open fails the command" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  _dvw_pin_open_pr() { return 1; }
  run cmd_pin_sync demo
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "couldn't open the PR"
}

@test "pin-sync: catalog discovery failure is not a silent success" {
  catalog_workspace_ids() { return 1; }
  run cmd_pin_sync
  [ "$status" -ne 0 ]
}

_install_pin_pr_gh_stub() {
  PIN_FILE_CONTENT="$1"
  gh() {
    if [[ "$*" == *"pr list -R vossiman/demo"* ]]; then printf '\n'; return 0; fi
    if [[ "$*" == *" -X PUT "*repos/vossiman/demo/contents/* ]]; then
      local i; for ((i=1; i<=$#; i++)); do [[ "${!i}" == content=* ]] && break; done
      printf '%s' "${!i#content=}" | base64 -d > "$BATS_TEST_TMPDIR/put.json"
      return 0
    fi
    if [[ "$*" == *repos/vossiman/demo/contents/.devcontainer/devcontainer.json* ]]; then
      jq -n --arg c "$(printf '%s' "$PIN_FILE_CONTENT" | base64 -w0)" '{sha:"deadbeef",content:$c}'
      return 0
    fi
    if [[ "$*" == *repos/vossiman/demo/git/ref/heads/main* ]]; then printf 'abc123\n'; return 0; fi
    if [[ "$*" == *repos/vossiman/demo/git/refs* ]]; then return 0; fi
    if [[ "$*" == *"pr create -R vossiman/demo"* ]]; then printf 'https://github.com/vossiman/demo/pull/9\n'; return 0; fi
    echo "unexpected gh call: $*" >&2; return 99
  }
}

# review 2026-08-21: the digest-only sed no-oped on tag pins, PUT a
# byte-identical file and reported an empty PR as success. The production
# transition is tag -> blueprint digest, not the tag -> tag case alone.
@test "pin PR: an existing tag is replaced by the blueprint digest" {
  _install_pin_pr_gh_stub '{"image":"ghcr.io/vossiman/devbox-base:2026-08-01"}'
  run _dvw_pin_open_pr vossiman/demo main "$BP_IMAGE"
  [ "$status" -eq 0 ]
  grep -qF "$BP_IMAGE" "$BATS_TEST_TMPDIR/put.json"
}

@test "pin PR: registry-less existing refs are replaced completely" {
  _install_pin_pr_gh_stub '{"image":"vossiman/devbox-base:old.tag"}'
  run _dvw_pin_open_pr vossiman/demo main "$BP_IMAGE"
  [ "$status" -eq 0 ]
  grep -qF "$BP_IMAGE" "$BATS_TEST_TMPDIR/put.json"
}

@test "pin PR: JSONC comments around the image key survive" {
  _install_pin_pr_gh_stub $'{\n  // old example: "image": "example.invalid/do-not-edit:latest"\n  "image": "ghcr.io/vossiman/devbox-base:old.tag", // keep this note\n  "customizations": {}\n}'
  run _dvw_pin_open_pr vossiman/demo main "$BP_IMAGE"
  [ "$status" -eq 0 ]
  grep -qF "$BP_IMAGE" "$BATS_TEST_TMPDIR/put.json"
  grep -qF '"image": "example.invalid/do-not-edit:latest"' "$BATS_TEST_TMPDIR/put.json"
  grep -qF '// keep this note' "$BATS_TEST_TMPDIR/put.json"
}

# review 2026-08-24: a `/* */` block-comment example ahead of the real property
# was rewritten instead of the pin. The file changed, so the no-op guard never
# fired and a stale pin was PUT as a "successful" PR.
@test "pin PR: a block-comment image example is not mistaken for the pin" {
  _install_pin_pr_gh_stub $'{\n  /*\n  "image": "example.invalid/do-not-edit:latest",\n  */\n  "image": "ghcr.io/vossiman/devbox-base:old.tag"\n}'
  run _dvw_pin_open_pr vossiman/demo main "$BP_IMAGE"
  [ "$status" -eq 0 ]
  # the real pin is rewritten...
  grep -qF "$BP_IMAGE" "$BATS_TEST_TMPDIR/put.json"
  # ...and the commented example survives byte-identically.
  grep -qF '"image": "example.invalid/do-not-edit:latest"' "$BATS_TEST_TMPDIR/put.json"
}

@test "rebuild pre-flight: a current pin passes straight through" {
  _dvw_repo_pin() { printf '%s\n' "$BP_IMAGE"; }
  ui_confirm() { echo "SHOULD NOT ASK"; return 0; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT ASK"
}

# WIRING: cmd_recreate calls `devpod up --recreate` directly, bypassing
# _dvw_safe_devpod_up. --configure-ssh defaults true, so the rebuild rewrites
# the stanza with `ForwardAgent yes`; without an explicit reconcile here every
# `dvw recreate` silently re-opens full-keyring agent forwarding.
_stub_recreate_deps() {
  _dvw_ensure_local_devpod_state()     { return 0; }
  _dvw_resolve_canonical_container()   { return 0; }
  _dvw_reap_stale_masters()            { :; }
  _dvw_pin_preflight()                 { return 0; }
  catalog_workspace_set_devpod_state() { :; }
  _dvw_run_or_print() { echo "ran:$*" >> "$BATS_TEST_TMPDIR/calls"; return "${UP_RC:-0}"; }
  _dvw_ensure_ssh_alias() { echo "reconciled:$1" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
}

@test "cmd_recreate: reconciles the ssh alias after the rebuild" {
  _stub_recreate_deps
  run cmd_recreate demo
  [ "$status" -eq 0 ]
  grep -q "ran:devpod up demo --recreate" "$BATS_TEST_TMPDIR/calls"
  grep -qx "reconciled:demo" "$BATS_TEST_TMPDIR/calls"
}

@test "cmd_recreate: does NOT reconcile when the rebuild failed" {
  _stub_recreate_deps
  UP_RC=1
  run cmd_recreate demo
  [ "$status" -ne 0 ]
  ! grep -q "reconciled:demo" "$BATS_TEST_TMPDIR/calls"
}

@test "rebuild pre-flight: a stale pin OFFERS pin-sync and aborts when accepted" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { return 0; }          # user says yes
  cmd_pin_sync() { echo "PIN SYNC RAN"; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 1 ]                 # non-zero = cmd_recreate skips the rebuild
  echo "$output" | grep -q "PIN SYNC RAN"
}

@test "rebuild pre-flight: declining the offer proceeds with the rebuild" {
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { return 1; }          # user says no
  cmd_pin_sync() { echo "SHOULD NOT RUN"; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]                 # zero = cmd_recreate goes ahead
  ! echo "$output" | grep -q "SHOULD NOT RUN"
}

@test "rebuild pre-flight: no gh CLI means silent pass-through, never a block" {
  command() { if [ "$2" = gh ]; then return 1; fi; builtin command "$@"; }
  _dvw_repo_pin() { printf '%s\n' "$OLD_IMAGE"; }
  ui_confirm() { echo "SHOULD NOT ASK"; return 0; }
  run _dvw_pin_preflight demo
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD NOT ASK"
}

@test "dispatch: dvw pin-sync reaches cmd_pin_sync with its args" {
  cmd_pin_sync() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/argv"; }
  run main pin-sync demo
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = "demo" ]
}
