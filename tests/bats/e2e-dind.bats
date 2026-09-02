#!/usr/bin/env bats
# Opt-in end-to-end run against docker:dind. Skipped unless DVW_E2E=1 so the
# normal suite stays fast and offline.

@test "e2e: proxy + catalog + probe against docker-in-docker" {
  [ "${DVW_E2E:-}" = "1" ] || skip "set DVW_E2E=1 to run the dind harness"
  run bash "$DVW_ROOT/tests/e2e/dind.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"e2e ok"* ]]
}
