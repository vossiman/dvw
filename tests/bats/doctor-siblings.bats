#!/usr/bin/env bats
# _dvw_doctor_sibling_detail: name WHICH duplicate container to remove.
#
# Detecting "this workspace has 2 containers" is not enough to act on — the
# operator still has to know which one is safe to delete. These assert the two
# signals that decided it in the 2026-07-26 incident: a live tmux `work`
# session (connect routes there) and /workspaces ownership (root = never
# provisioned).

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  export DVW_ROOT
  source "$DVW_ROOT/lib/ui.sh"
  source "$DVW_ROOT/lib/commands.sh"
}

# NB: the payload must be a GLOBAL. A `local` here would be out of scope by the
# time _catalog_req is invoked — bash functions don't close over locals.
_stub_siblings() {
  SIBLINGS_JSON="$1"
  _catalog_req() { printf '%s' "$SIBLINGS_JSON"; }
}

@test "sibling detail: marks the provisioned tmux-bearing container KEEP and the root-owned one DUD" {
  _stub_siblings '[
    {"container_id":"cfa733fb6dda1111","container_name":"elated_perlman","tmux_work_activity":555,"workspaces_owner":"codespace:codespace"},
    {"container_id":"458add1087e72222","container_name":"elated_wu","tmux_work_activity":-1,"workspaces_owner":"root:root"}
  ]'
  run _dvw_doctor_sibling_detail handsfree-git-main
  [ "$status" -eq 0 ]
  [[ "$output" == *"cfa733fb6dda"* ]]
  [[ "$output" == *"458add1087e7"* ]]
  echo "$output" | grep -q "cfa733fb6dda.*KEEP"
  echo "$output" | grep -q "458add1087e7.*DUD"
}

@test "sibling detail: provisioned but tmux-less is 'unclear', never auto-condemned" {
  _stub_siblings '[
    {"container_id":"aaaa11112222","container_name":"one","tmux_work_activity":-1,"workspaces_owner":"codespace:codespace"},
    {"container_id":"bbbb33334444","container_name":"two","tmux_work_activity":-1,"workspaces_owner":"codespace:codespace"}
  ]'
  run _dvw_doctor_sibling_detail ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclear"* ]]
  [[ "$output" != *"DUD"* ]]
}

@test "sibling detail: degrades gracefully when the service predates /siblings" {
  _catalog_req() { return 1; }
  run _dvw_doctor_sibling_detail ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
}

@test "sibling detail: tolerates a missing owner field" {
  _stub_siblings '[{"container_id":"cccc55556666","container_name":"x","tmux_work_activity":-1}]'
  run _dvw_doctor_sibling_detail ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"cccc55556666"* ]]
}
