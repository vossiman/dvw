from __future__ import annotations

import json

import pytest

from app.blueprint_store import (
    MANAGED_BLOCK,
    MANAGED_VERSION,
    BlueprintConflictError,
    BlueprintStore,
    FutureBlueprintVersionError,
    extract_custom_content,
)

LEGACY_PREAMBLE = """\
# dvw blueprint — served by dvw-catalog (GET /v1/blueprint).
# Edit via `dvw -l`/the service; all machines pick it up on the next dvw call.
# Personal/host-specific config stays in ~/.ssh/config; only put shared
# config here.

"""

LEGACY_BLOCK_V1 = """\
Host *.devpod
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
"""

LEGACY_BLOCK_V2 = (
    LEGACY_BLOCK_V1
    + """\
  ServerAliveInterval 5
  ServerAliveCountMax 3
"""
)


def _store(tmp_path) -> BlueprintStore:
    return BlueprintStore(
        effective_path=tmp_path / "ssh-blueprint.conf",
        custom_path=tmp_path / "ssh-blueprint.custom.conf",
        meta_path=tmp_path / "ssh-blueprint.meta.json",
        legacy_backup_path=tmp_path / "ssh-blueprint.legacy.bak",
    )


def test_fresh_store_materializes_generated_defaults(tmp_path):
    store = _store(tmp_path)

    snapshot = store.read()

    assert snapshot.content == MANAGED_BLOCK
    assert snapshot.custom_content == ""
    assert snapshot.managed_version == MANAGED_VERSION
    assert snapshot.migration_status == "fresh_initialized"
    assert snapshot.revision.startswith("sha256:")
    assert store.custom_path.read_text() == ""
    assert store.effective_path.read_text() == MANAGED_BLOCK
    assert json.loads(store.meta_path.read_text()) == {
        "schema_version": 1,
        "managed_version": MANAGED_VERSION,
    }
    assert not store.legacy_backup_path.exists()


def test_exact_legacy_defaults_migrate_to_empty_custom_content(tmp_path):
    store = _store(tmp_path)
    legacy = LEGACY_PREAMBLE + LEGACY_BLOCK_V1
    store.effective_path.write_text(legacy)

    snapshot = store.read()

    assert snapshot.migration_status == "legacy_defaults_removed"
    assert snapshot.custom_content == ""
    assert snapshot.content == MANAGED_BLOCK
    assert store.legacy_backup_path.read_text() == legacy


def test_known_legacy_block_is_removed_but_extra_content_is_preserved(tmp_path):
    store = _store(tmp_path)
    extra = "Host buildbox\n  User builder\n"
    legacy = LEGACY_PREAMBLE + LEGACY_BLOCK_V1 + "\n" + extra
    store.effective_path.write_text(legacy)

    snapshot = store.read()

    assert snapshot.migration_status == "legacy_defaults_removed"
    assert snapshot.custom_content == extra
    assert snapshot.content.startswith(extra + "\n")
    assert snapshot.content.endswith(MANAGED_BLOCK)
    assert store.legacy_backup_path.read_text() == legacy


def test_v2_legacy_block_is_removed_as_one_unit(tmp_path):
    store = _store(tmp_path)
    extra = "Host buildbox\n  User builder\n"
    store.effective_path.write_text(LEGACY_PREAMBLE + LEGACY_BLOCK_V2 + "\n" + extra)

    snapshot = store.read()

    assert snapshot.custom_content == extra
    assert snapshot.content.startswith(extra + "\n")
    assert snapshot.content.count("ServerAliveInterval 5") == 1


def test_unknown_legacy_content_is_preserved_byte_for_byte(tmp_path):
    store = _store(tmp_path)
    legacy = "Host *.devpod\n  ProxyJump unusual-gateway\n\n# keep this\n"
    store.effective_path.write_text(legacy)

    snapshot = store.read()

    assert snapshot.migration_status == "legacy_preserved"
    assert snapshot.custom_content == legacy
    assert store.custom_path.read_text() == legacy
    assert snapshot.content.startswith(legacy.rstrip("\n") + "\n\n")
    assert store.legacy_backup_path.read_text() == legacy


def test_read_repairs_tampered_materialized_file_from_custom_source(tmp_path):
    store = _store(tmp_path)
    store.write_custom("Host buildbox\n  User builder\n")
    expected = store.read().content
    store.effective_path.write_text("tampered\n")

    repaired = store.read()

    assert repaired.content == expected
    assert store.effective_path.read_text() == expected
    assert store.custom_path.read_text() == "Host buildbox\n  User builder\n"


def test_managed_materialization_can_be_recovered_if_custom_file_is_lost(tmp_path):
    store = _store(tmp_path)
    effective = "Host buildbox\n  User builder\n\n" + MANAGED_BLOCK
    store.effective_path.write_text(effective)

    snapshot = store.read()

    assert snapshot.migration_status == "managed_materialization_recovered"
    assert snapshot.custom_content == "Host buildbox\n  User builder\n"
    assert snapshot.content == effective


def test_custom_override_precedes_defaults_and_changes_revision(tmp_path):
    store = _store(tmp_path)
    before = store.read()

    after = store.write_custom("Host *.devpod\n  ServerAliveInterval 10\n")

    assert after.revision != before.revision
    assert after.content.index("ServerAliveInterval 10") < after.content.index(
        "ServerAliveInterval 5"
    )


def test_stale_revision_and_managed_markers_are_rejected(tmp_path):
    store = _store(tmp_path)
    current = store.read()
    store.write_custom("Host one\n")

    with pytest.raises(BlueprintConflictError, match="revision changed"):
        store.write_custom("Host stale\n", current.revision)

    with pytest.raises(BlueprintConflictError, match="cannot contain"):
        store.write_custom(MANAGED_BLOCK)


def test_effective_round_trip_extracts_custom_and_rejects_managed_edit(tmp_path):
    store = _store(tmp_path)
    custom = "Host buildbox\n  User builder\n"
    effective = store.write_custom(custom).content

    assert extract_custom_content(effective) == custom

    modified = effective.replace("ControlPersist 10m", "ControlPersist 1h")
    with pytest.raises(BlueprintConflictError, match="cannot be edited"):
        extract_custom_content(modified)


def test_effective_round_trip_tolerates_trailing_newline_changes(tmp_path):
    """A shell `$(...)` capture strips the final newline; that is not an edit."""
    store = _store(tmp_path)
    custom = "Host buildbox\n  User builder\n"
    effective = store.write_custom(custom).content

    assert extract_custom_content(effective.rstrip("\n")) == custom
    assert extract_custom_content(effective + "\n\n") == custom


def test_seeded_effective_copy_without_trailing_newline_does_not_wedge(tmp_path):
    """The documented `scp ssh-blueprint.conf` seeding path must stay readable.

    The client writes its local copy with `printf '%s'`, so a copy taken from a
    machine and dropped into the data dir has lost the final newline. Treating
    that as custom data used to persist managed markers into the custom file and
    make every later read fail.
    """
    store = _store(tmp_path)
    custom = "Host buildbox\n  User builder\n"
    store.effective_path.write_text((custom + "\n" + MANAGED_BLOCK).rstrip("\n"))

    snapshot = store.read()

    assert snapshot.migration_status == "managed_materialization_recovered"
    assert snapshot.custom_content == custom
    assert snapshot.content == custom + "\n" + MANAGED_BLOCK
    assert store.read().content == snapshot.content  # still readable, not wedged


def test_managed_markers_in_the_custom_file_are_repaired_on_read(tmp_path):
    store = _store(tmp_path)
    store.custom_path.write_text("Host buildbox\n  User builder\n\n" + MANAGED_BLOCK)

    snapshot = store.read()

    assert snapshot.migration_status == "custom_sanitized"
    assert snapshot.custom_content == "Host buildbox\n  User builder\n"
    assert store.custom_path.read_text() == "Host buildbox\n  User builder\n"
    assert snapshot.content.count("ControlPersist 10m") == 1
    assert store.read().migration_status == "current"


def test_future_schema_or_managed_version_is_never_downgraded(tmp_path):
    store = _store(tmp_path)
    store.custom_path.write_text("")
    store.meta_path.write_text(
        json.dumps({"schema_version": 1, "managed_version": MANAGED_VERSION + 1})
    )

    with pytest.raises(FutureBlueprintVersionError, match="newer"):
        store.read()

    store.meta_path.write_text(
        json.dumps({"schema_version": 2, "managed_version": MANAGED_VERSION})
    )
    with pytest.raises(FutureBlueprintVersionError, match="newer"):
        store.read()


def test_older_metadata_schema_is_upgraded(tmp_path):
    store = _store(tmp_path)
    store.custom_path.write_text("")
    store.meta_path.write_text(
        json.dumps({"schema_version": 0, "managed_version": MANAGED_VERSION})
    )

    snapshot = store.read()

    assert snapshot.migration_status == "schema_upgraded"
    assert json.loads(store.meta_path.read_text()) == {
        "schema_version": 1,
        "managed_version": MANAGED_VERSION,
    }
