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

    # Docker connection. The deployed posture is the socket proxy, not the
    # docker group: deploy/catalog.env.example ships
    # CATALOG_DOCKER_HOST=tcp://127.0.0.1:2375 and dvw-catalog.service carries
    # no SupplementaryGroups=docker, so a deployed service always sets this.
    # Empty => docker.from_env() (local /var/run/docker.sock, which needs
    # docker-group membership); that path is for local development only.
    # deploy/docker-socket-proxy.md spells out what the proxy does and does not
    # buy — notably, it narrows the API surface but does not remove host-root
    # equivalence.
    docker_host: str = ""

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
        return (self.devpod_agent_workspaces_dir.expanduser()
                / ws_id / "content")


@lru_cache
def get_settings() -> Settings:
    return Settings()
