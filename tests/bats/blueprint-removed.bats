#!/usr/bin/env bats
#
# spec #2 (devcontainer dedup): the devcontainer `blueprint` command is gone.
# dvw is client-side and never the source of truth for devcontainer.json —
# aiCodingBaseSetup owns the canonical file. These guard against the command,
# its implementation, and the template directory creeping back in.
#
# (Unrelated: the SSH-config "blueprint" in lib/ssh-sync.sh stays — different
# concept. Tests here target only the devcontainer blueprint surface.)

setup() {
  : "${DVW_ROOT:?}"
}

@test "dispatcher: no longer routes 'blueprint' to cmd_blueprint" {
  run grep -nE 'cmd_blueprint' "$DVW_ROOT/dvw"
  [ "$status" -ne 0 ]
}

@test "commands.sh: cmd_blueprint is not defined" {
  source "$DVW_ROOT/lib/commands.sh"
  run declare -f cmd_blueprint
  [ "$status" -ne 0 ]
}

@test "ui top menu: no 'Install blueprint' entry" {
  run grep -nE 'Install blueprint|cmd_blueprint' "$DVW_ROOT/lib/ui.sh"
  [ "$status" -ne 0 ]
}

@test "blueprint/ template directory is removed" {
  [ ! -e "$DVW_ROOT/blueprint" ]
}
