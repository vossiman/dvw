#!/usr/bin/env bats
# configure-backup-remote.sh gives /var/lib/dvw-catalog's git repo a push
# destination from CATALOG_BACKUP_REMOTE, so the backup unit's plain
# `git push` works. A bare repo stands in for GitHub.

setup() {
  DVW_ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="$DVW_ROOT/catalog-service/deploy/configure-backup-remote.sh"
  HELPER="$DVW_ROOT/catalog-service/deploy/gh-token-helper"
  DATA="$BATS_TEST_TMPDIR/data"; BARE="$BATS_TEST_TMPDIR/bare.git"; ENV="$BATS_TEST_TMPDIR/catalog.env"
  git init -q --bare "$BARE"
  git init -q "$DATA"
  git -C "$DATA" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'CATALOG_BACKUP_PUSH_URL=\nCATALOG_BACKUP_REMOTE=%s\n' "$BARE" > "$ENV"
}

@test "unset remote is a no-op that says so" {
  printf 'OTHER=1\n' > "$ENV"
  run bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CATALOG_BACKUP_REMOTE unset"* ]]
  ! git -C "$DATA" remote get-url origin
}

@test "sets origin, helper and upstream so a plain git push reaches the remote" {
  run bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(git -C "$DATA" remote get-url origin)" = "$BARE" ]
  [ "$(git -C "$DATA" config credential.helper)" = "$HELPER" ]
  [ "$(git -C "$DATA" rev-parse --abbrev-ref HEAD)" = "main" ]
  git -C "$DATA" push --quiet
  [ "$(git -C "$BARE" rev-parse main)" = "$(git -C "$DATA" rev-parse main)" ]
}

@test "re-running with a changed value moves origin and keeps working" {
  bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  git -C "$DATA" push --quiet
  OTHER="$BATS_TEST_TMPDIR/other.git"; git init -q --bare "$OTHER"
  printf 'CATALOG_BACKUP_REMOTE="%s"\n' "$OTHER" > "$ENV"
  run bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(git -C "$DATA" remote get-url origin)" = "$OTHER" ]
  git -C "$DATA" push --quiet
  [ "$(git -C "$OTHER" rev-parse main)" = "$(git -C "$DATA" rev-parse main)" ]
}

@test "a stale hand-set upstream is repointed at origin/main" {
  STALE="$BATS_TEST_TMPDIR/stale.git"; git init -q --bare "$STALE"
  git -C "$DATA" remote add backup "$STALE"
  git -C "$DATA" branch -M main
  git -C "$DATA" push -q -u backup main
  run bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(git -C "$DATA" config branch.main.remote)" = "origin" ]
  git -C "$DATA" push --quiet
  [ "$(git -C "$BARE" rev-parse main)" = "$(git -C "$DATA" rev-parse main)" ]
}

@test "unset with an existing origin reports that origin stays in use" {
  bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  printf 'OTHER=1\n' > "$ENV"
  run bash "$SCRIPT" "$DATA" "$ENV" "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeps pushing to $BARE"* ]]
  [ "$(git -C "$DATA" remote get-url origin)" = "$BARE" ]
}

@test "the updater re-runs itself when the pull changed it" {
  grep -q 'DVW_UPDATE_REEXEC=1 exec bash "\$SVC_DIR/deploy/host-update.sh"' "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}

@test "the installer and updater both call it with the helper" {
  grep -q 'configure-backup-remote.sh" "\$DATA_DIR" "\$SVC_DIR/catalog.env" "\$GH_HELPER"' "$DVW_ROOT/catalog-service/deploy/host-install.sh"
  grep -q 'configure-backup-remote.sh" /var/lib/dvw-catalog "\$SVC_DIR/catalog.env" "\$GH_HELPER"' "$DVW_ROOT/catalog-service/deploy/host-update.sh"
}
