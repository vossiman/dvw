#!/usr/bin/env bats
#
# ui_confirm — plain-bash yes/no prompt (replaced gum confirm, 2026-08-11).
# Fail-closed on non-TTY stdin; DVW_ASSUME_TTY=1 lets tests pipe answers.

setup() {
  source "$DVW_ROOT/lib/ui.sh"
}

@test "ui_confirm: y answers yes (rc 0)" {
  export DVW_ASSUME_TTY=1
  run ui_confirm "Proceed?" <<< "y"
  [ "$status" -eq 0 ]
}

@test "ui_confirm: Y and yes also answer yes" {
  export DVW_ASSUME_TTY=1
  run ui_confirm "Proceed?" <<< "Y"
  [ "$status" -eq 0 ]
  run ui_confirm "Proceed?" <<< "yes"
  [ "$status" -eq 0 ]
}

@test "ui_confirm: n, empty line, and garbage answer no (rc 1)" {
  export DVW_ASSUME_TTY=1
  run ui_confirm "Proceed?" <<< "n"
  [ "$status" -eq 1 ]
  run ui_confirm "Proceed?" <<< ""
  [ "$status" -eq 1 ]
  run ui_confirm "Proceed?" <<< "wat"
  [ "$status" -eq 1 ]
}

@test "ui_confirm: EOF (closed stdin) answers no" {
  export DVW_ASSUME_TTY=1
  run ui_confirm "Proceed?" < /dev/null
  [ "$status" -eq 1 ]
}

@test "ui_confirm: non-TTY stdin fails closed with a message" {
  unset DVW_ASSUME_TTY
  run ui_confirm "Proceed?" <<< "y"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "non-interactive"
}

@test "ui_confirm: prompt text appears (on stderr)" {
  export DVW_ASSUME_TTY=1
  run ui_confirm "Delete everything?" <<< "n"
  echo "$output" | grep -q "Delete everything?"
}
