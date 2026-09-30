#!/usr/bin/env bash
# Refresh the vendored aicoding CI selector from ONE aiCodingBaseSetup main
# commit, or with --check only report whether the copy still matches it.
# Spec: docs/superpowers/specs/2026-09-27-catalog-vendored-selector.md
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=vossiman/aiCodingBaseSetup
FILES=(bin/aicoding-select lib/ci-selector.sh lib/update-progress.sh lib/ui.sh)
RAW_BASE=${AICODING_VENDOR_RAW_BASE:-https://raw.githubusercontent.com/$REPO}
GIT_URL=${AICODING_VENDOR_GIT_URL:-https://github.com/$REPO}

check=0
case "${1:-}" in
  '') ;;
  --check) check=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

sha=$(git ls-remote "$GIT_URL" refs/heads/main | awk 'NR == 1 { print $1 }') || sha=
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: could not resolve $REPO main to a commit" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for f in "${FILES[@]}"; do
  mkdir -p "$tmp/$(dirname "$f")"
  if ! curl -fsSL --max-time 30 "$RAW_BASE/$sha/$f" -o "$tmp/$f"; then
    echo "error: could not download $f at $sha; the vendored copy is unchanged" >&2
    exit 2
  fi
done

if [ "$check" -eq 1 ]; then
  drift=()
  for f in "${FILES[@]}"; do
    cmp -s "$tmp/$f" "$HERE/$f" || drift+=("$f")
  done
  if [ "${#drift[@]}" -gt 0 ]; then
    echo "vendored selector differs from $REPO@$sha: ${drift[*]}" >&2
    echo "run catalog-service/vendor/aicoding/refresh.sh, review the diff, open a PR" >&2
    exit 1
  fi
  echo "vendored selector matches $REPO@$sha"
  exit 0
fi

{
  echo "# Written by refresh.sh. Provenance only: nothing at runtime reads this file."
  echo "repo=$REPO"
  echo "commit=$sha"
  for f in "${FILES[@]}"; do
    printf '%s  %s\n' "$(sha256sum "$tmp/$f" | cut -d' ' -f1)" "$f"
  done
} > "$tmp/SOURCE"
for f in "${FILES[@]}"; do
  mkdir -p "$HERE/$(dirname "$f")"
  install -m 0644 "$tmp/$f" "$HERE/$f"
done
chmod 0755 "$HERE/bin/aicoding-select"
install -m 0644 "$tmp/SOURCE" "$HERE/SOURCE"
echo "vendored selector refreshed to $REPO@$sha"
