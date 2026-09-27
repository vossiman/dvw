from __future__ import annotations

import hashlib
from pathlib import Path

VENDOR = Path(__file__).resolve().parent.parent / "vendor" / "aicoding"
FILES = ("bin/aicoding-select", "lib/ci-selector.sh", "lib/update-progress.sh")


def _source():
    entries, meta = {}, {}
    for line in (VENDOR / "SOURCE").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if "=" in line and "  " not in line:
            key, value = line.split("=", 1)
            meta[key] = value
        else:
            digest, path = line.split("  ", 1)
            entries[path] = digest
    return meta, entries


def test_source_names_one_exact_upstream_commit():
    meta, _ = _source()
    assert meta["repo"] == "vossiman/aiCodingBaseSetup"
    assert len(meta["commit"]) == 40 and all(c in "0123456789abcdef" for c in meta["commit"])


def test_vendored_files_match_their_recorded_digests():
    _, entries = _source()
    assert sorted(entries) == sorted(FILES)
    for rel in FILES:
        assert hashlib.sha256((VENDOR / rel).read_bytes()).hexdigest() == entries[rel], rel


def test_vendored_selector_is_executable():
    assert (VENDOR / "bin" / "aicoding-select").stat().st_mode & 0o111
