"""Runtime configuration, sourced from environment variables.

Everything has a sensible default so the service starts with no env file for
local development. On vossisrv the systemd unit points the data paths at
/var/lib/dvw-catalog and (optionally) DOCKER_HOST at the socket-proxy.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CATALOG_", extra="ignore")

    # Where the single JSON catalog lives. Plain, deliberately simple JSON so
    # the file stays hand-editable and trivial to copy between hosts.
    data_dir: Path = Path("/var/lib/dvw-catalog")
    catalog_filename: str = "catalog.json"
    blueprint_filename: str = "ssh-blueprint.conf"
    blueprint_custom_filename: str = "ssh-blueprint.custom.conf"
    blueprint_meta_filename: str = "ssh-blueprint.meta.json"
    blueprint_legacy_backup_filename: str = "ssh-blueprint.legacy.bak"

    # Optional shared secret. When unset (the default), the service relies on
    # the unix-socket + SSH-key auth boundary and does NOT require a token.
    # When set, every /v1 request must send `Authorization: Bearer <token>`.
    token: str | None = None

    # Docker connection. The deployed posture is dvw-docker-proxy on a unix
    # socket that systemd creates with mode 0600 for the catalog user
    # (deploy/dvw-docker-proxy.socket); the service itself has no docker
    # group membership and no TCP. Set CATALOG_DOCKER_HOST to
    # unix:/var/run/docker.sock only for local development with docker-group
    # access. Empty is no longer a supported value.
    docker_host: str = "unix:///run/dvw-docker-proxy/docker.sock"

    # The bind-mount destination prefix devpod uses inside every container.
    # The exact workspace id is the trailing path component: /workspaces/<id>.
    workspace_mount_prefix: str = "/workspaces/"

    # Label devpod stamps on every managed container (value is the uid).
    devpod_id_label: str = "dev.containers.id"

    # Resolver result cache TTL, seconds. The common single-match path is
    # collapsed to near-zero work; 0 disables the cache.
    resolve_cache_ttl: float = 8.0

    # Docker API call timeout, seconds.
    docker_timeout: int = 10

    # The aicoding blueprint devcontainer.json (owns the current image pin).
    blueprint_devcontainer_url: str = (
        "https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup"
        "/main/devcontainer.json")
    # Blueprint image cache TTL, seconds.
    blueprint_image_ttl: float = 900.0

    # devpod agent workspace dirs on this box; each workspace's build source
    # is <dir>/<id>/content. "~" is the service account (vossi on vossisrv).
    devpod_agent_workspaces_dir: Path = Path(
        "~/.devpod/agent/contexts/default/workspaces")

    @property
    def catalog_path(self) -> Path:
        return self.data_dir / self.catalog_filename

    @property
    def blueprint_path(self) -> Path:
        return self.data_dir / self.blueprint_filename

    @property
    def blueprint_custom_path(self) -> Path:
        return self.data_dir / self.blueprint_custom_filename

    @property
    def blueprint_meta_path(self) -> Path:
        return self.data_dir / self.blueprint_meta_filename

    @property
    def blueprint_legacy_backup_path(self) -> Path:
        return self.data_dir / self.blueprint_legacy_backup_filename

    def source_path(self, ws_id: str) -> Path:
        # ws_id reaches here via a route pattern that allows "." and "-", so
        # ".." or a path with a leading "/" is a legal ws_id string as far as
        # FastAPI is concerned. Resolve and assert containment so a crafted
        # ws_id can't walk the source path outside the agent workspaces dir.
        base = self.devpod_agent_workspaces_dir.expanduser().resolve()
        p = (base / ws_id / "content").resolve()
        if not p.is_relative_to(base):
            raise ValueError(f"ws_id resolves outside the workspaces dir: {ws_id!r}")
        return p


@lru_cache
def get_settings() -> Settings:
    return Settings()
