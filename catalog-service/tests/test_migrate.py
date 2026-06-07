from __future__ import annotations

import json

from app.migrate import migrate
from app.models import Catalog


def _legacy_catalog():
    return {
        "version": 1,
        "defaults": {"ide": "cursor", "provider": "vossisrv"},
        "workspaces": [
            {
                "id": "devmachine-git",
                "repo": "git@github.com:me/devmachine",
                "branch": "main",
                "ide": "cursor",
                "provider": "vossisrv",
                "created_at": "2026-05-01T10:00:00Z",
                "last_used_at": "2026-06-01T10:00:00Z",
                "uid": "default-de-54406",
            }
        ],
        "repos": [
            {"url": "git@github.com:me/devmachine", "last_branch": "main",
             "last_used_at": "2026-06-01T10:00:00Z"}
        ],
    }


def test_migrate_imports_workspaces_and_blueprint(tmp_path):
    src = tmp_path / "catalog.json"
    src.write_text(json.dumps(_legacy_catalog()))
    bp = tmp_path / "ssh-blueprint.conf"
    bp.write_text("Host *.devpod\n  ControlMaster auto\n")
    data_dir = tmp_path / "data"

    rc = migrate(src, bp, data_dir, force=False)
    assert rc == 0

    imported = Catalog.model_validate(json.loads((data_dir / "catalog.json").read_text()))
    assert imported.workspaces[0].id == "devmachine-git"
    assert imported.workspaces[0].uid == "default-de-54406"
    assert (data_dir / "ssh-blueprint.conf").read_text().startswith("Host *.devpod")


def test_migrate_refuses_to_clobber_without_force(tmp_path):
    src = tmp_path / "catalog.json"
    src.write_text(json.dumps(_legacy_catalog()))
    data_dir = tmp_path / "data"
    assert migrate(src, None, data_dir, force=False) == 0
    # Second run without --force must refuse (existing non-empty catalog).
    assert migrate(src, None, data_dir, force=False) == 1
    assert migrate(src, None, data_dir, force=True) == 0


def test_migrate_missing_source(tmp_path):
    assert migrate(tmp_path / "nope.json", None, tmp_path / "data", False) == 1
