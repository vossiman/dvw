"""One-shot importer: legacy Dropbox catalog -> the service's data dir.

Usage:
    uv run dvw-catalog-migrate \\
        --from ~/Dropbox-remote/dvw/catalog.json \\
        --blueprint ~/Dropbox-remote/dvw/ssh-blueprint.conf \\
        --data-dir /var/lib/dvw-catalog

Refuses to clobber an existing non-empty catalog unless --force is given.
Validates against the Pydantic models before writing (atomic).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .models import Catalog


def _warn_on_conflicted_copies(src: Path) -> None:
    siblings = list(src.parent.glob("*conflicted copy*"))
    if siblings:
        print(
            f"WARNING: Dropbox conflicted-copy files present near {src}:",
            file=sys.stderr,
        )
        for s in siblings:
            print(f"  - {s.name}", file=sys.stderr)
        print(
            "  Importing ONLY the canonical file. Verify it is the newest good copy.",
            file=sys.stderr,
        )


def migrate(src: Path, blueprint: Path | None, data_dir: Path, force: bool) -> int:
    if not src.exists():
        print(f"source catalog not found: {src}", file=sys.stderr)
        return 1
    _warn_on_conflicted_copies(src)

    catalog = Catalog.model_validate(json.loads(src.read_text()))

    data_dir.mkdir(parents=True, exist_ok=True)
    dest = data_dir / "catalog.json"
    if dest.exists() and dest.stat().st_size > 0 and not force:
        existing = Catalog.model_validate(json.loads(dest.read_text()))
        if existing.workspaces:
            print(
                f"refusing to overwrite non-empty catalog at {dest} (use --force)",
                file=sys.stderr,
            )
            return 1

    # Import via the store so the write path (atomic + fsync) is identical to
    # the running service.
    from .store import CatalogStore  # local import: avoids asyncio at import

    store = CatalogStore(dest)
    store._catalog = catalog  # noqa: SLF001 — one-shot importer, intentional
    store._save()  # noqa: SLF001
    print(
        f"imported {len(catalog.workspaces)} workspace(s), "
        f"{len(catalog.repos)} repo(s) -> {dest}"
    )

    if blueprint and blueprint.exists():
        bp_dest = data_dir / "ssh-blueprint.conf"
        bp_dest.write_text(blueprint.read_text())
        print(f"imported ssh blueprint -> {bp_dest}")

    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Import legacy Dropbox dvw catalog.")
    p.add_argument("--from", dest="src", required=True, type=Path)
    p.add_argument("--blueprint", dest="blueprint", type=Path, default=None)
    p.add_argument("--data-dir", dest="data_dir", type=Path,
                   default=Path("/var/lib/dvw-catalog"))
    p.add_argument("--force", action="store_true",
                   help="overwrite an existing non-empty catalog")
    args = p.parse_args(argv)
    return migrate(args.src, args.blueprint, args.data_dir, args.force)


if __name__ == "__main__":
    raise SystemExit(main())
