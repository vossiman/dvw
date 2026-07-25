#!/usr/bin/env bash
# Show exactly what deploying this catalog service would do to an existing
# ssh-blueprint.conf — without touching the real one.
#
# The migration runs on the first GET after deployment and rewrites files in the
# service's data dir. Run this against a copy of the live blueprint first, read
# the diff, and only then deploy.
#
#   # on the laptop, against the live service:
#   dvw ... # or: curl --unix-socket /run/dvw-catalog/catalog.sock \
#           #        http://localhost/v1/blueprint | jq -r .content > /tmp/live-blueprint.conf
#   bash tests/manual/dry-run-blueprint-migration.sh /tmp/live-blueprint.conf
#
# Exits nonzero if the migration would drop any non-default line, so it is also
# usable as a pre-deploy gate.
set -uo pipefail

SRC="${1:-}"
[[ -n "$SRC" && -f "$SRC" ]] || { echo "usage: $0 <copy-of-ssh-blueprint.conf>" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$HERE/catalog-service/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$SRC" "$WORK/ssh-blueprint.conf"

PYTHONPATH="$HERE/catalog-service" "$PY" - "$WORK" "$SRC" <<'EOF'
import sys
from pathlib import Path

from app.blueprint_store import BlueprintStore, FutureBlueprintVersionError

work, src = Path(sys.argv[1]), Path(sys.argv[2])
before = (work / "ssh-blueprint.conf").read_text()

store = BlueprintStore(
    effective_path=work / "ssh-blueprint.conf",
    custom_path=work / "ssh-blueprint.custom.conf",
    meta_path=work / "ssh-blueprint.meta.json",
    legacy_backup_path=work / "ssh-blueprint.legacy.bak",
)

try:
    snap = store.read()
except FutureBlueprintVersionError as exc:
    print(f"REFUSED: {exc}")
    print("\nThis service would return 409 rather than touch the file. Nothing is")
    print("lost, but you are deploying an OLDER service than wrote that state.")
    raise SystemExit(1)

print(f"migration status : {snap.migration_status}")
print(f"managed version  : v{snap.managed_version}")
print(f"backup written   : {store.legacy_backup_path.name} "
      f"({'yes' if store.legacy_backup_path.exists() else 'no — nothing to back up'})")

print("\n--- kept as YOUR config (ssh-blueprint.custom.conf) ---")
print(snap.custom_content or "(empty — the old file was stock defaults only)")

print("--- served to clients afterwards (ssh-blueprint.conf) ---")
print(snap.content)

# Any non-comment, non-blank line that existed before must still be served,
# unless it is one of the defaults this service now generates itself.
def directives(text):
    return [l.strip() for l in text.splitlines()
            if l.strip() and not l.strip().startswith("#")]

after = snap.content
lost = [l for l in directives(before) if l not in directives(after)]
if lost:
    print("!! LINES THAT WOULD DISAPPEAR:")
    for line in lost:
        print(f"   {line}")
    print("\nDo NOT deploy until this is understood.")
    raise SystemExit(1)

# Presence is not enough: a directive that loses its enclosing Host block ends
# up applying to every host instead of the devpods, which is a silent widening
# rather than a loss. Anything indented above the first Host/Match is stranded.
stranded = []
for line in after.splitlines():
    bare = line.strip()
    if line[:1] not in " \t" and (bare.startswith("Host ") or bare.startswith("Match ")):
        break                      # reached the first stanza; nothing above it
    if bare and not bare.startswith("#") and line[:1] in " \t":
        stranded.append(line)
if stranded:
    print("!! DIRECTIVES THAT WOULD LOSE THEIR Host SCOPE (apply to ALL hosts):")
    for line in stranded:
        print(f"   {line}")
    print("\nDo NOT deploy until this is understood.")
    raise SystemExit(1)

print("OK: every directive is still present, and none lost its Host scope.")
EOF
