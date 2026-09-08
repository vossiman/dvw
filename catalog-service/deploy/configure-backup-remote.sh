#!/usr/bin/env bash
# Point the catalog data dir's git repo at CATALOG_BACKUP_REMOTE from
# catalog.env and give it credentials, so dvw-catalog-backup.service's plain
# `git push` has somewhere to go. Idempotent; a missing or empty value means
# "no off-box copy", and the script says so instead of failing.
#
#   configure-backup-remote.sh <data-dir> <catalog.env> <gh-token-helper>
set -euo pipefail

DATA_DIR="$1"; ENV_FILE="$2"; GH_HELPER="$3"

remote=""
[ -r "$ENV_FILE" ] && remote="$(sed -n 's/^[[:space:]]*CATALOG_BACKUP_REMOTE=//p' "$ENV_FILE" | head -n 1 | tr -d '"'"'"'[:space:]')"
if [ -z "$remote" ]; then
  if existing="$(git -C "$DATA_DIR" remote get-url origin 2>/dev/null)"; then
    echo "    CATALOG_BACKUP_REMOTE unset in $ENV_FILE; the backup keeps pushing to $existing" >&2
  else
    echo "    CATALOG_BACKUP_REMOTE unset in $ENV_FILE: no off-box copy of $DATA_DIR" >&2
  fi
  exit 0
fi

if git -C "$DATA_DIR" remote get-url origin >/dev/null 2>&1; then
  git -C "$DATA_DIR" remote set-url origin "$remote"
else
  git -C "$DATA_DIR" remote add origin "$remote"
fi
# The backup unit runs plain `git push` as the service user, outside the
# deploy scripts' git_auth wrapper, so the helper lives in this repo's config.
git -C "$DATA_DIR" config credential.helper "$GH_HELPER"
git -C "$DATA_DIR" branch -M main 2>/dev/null || true
# Unconditional: an upstream left over from a hand-configured remote would
# otherwise keep the nightly push going to the old destination.
git -C "$DATA_DIR" config branch.main.remote origin
git -C "$DATA_DIR" config branch.main.merge refs/heads/main
echo "    backup remote: origin -> $remote (upstream main)"
