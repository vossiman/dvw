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

    # Where the single JSON catalog lives. Same on-disk schema as the legacy
    # Dropbox catalog.json, so migration is a copy and it stays hand-editable.
    data_dir: Path = Path("/var/lib/dvw-catalog")
    catalog_filename: str = "catalog.json"
    blueprint_filename: str = "ssh-blueprint.conf"

    # Optional shared secret. When unset (the default), the service relies on
    # the unix-socket + SSH-key auth boundary and does NOT require a token.
    # When set, every /v1 request must send `Authorization: Bearer <token>`.
    token: str | None = None

    # Docker connection. Empty => docker.from_env() (local /var/run/docker.sock
    # via the `docker` group). Set to e.g. tcp://127.0.0.1:2375 to use the
    # tecnativa/docker-socket-proxy hardening (see deploy/docker-socket-proxy.md).
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

    @property
    def catalog_path(self) -> Path:
        return self.data_dir / self.catalog_filename

    @property
    def blueprint_path(self) -> Path:
        return self.data_dir / self.blueprint_filename


@lru_cache
def get_settings() -> Settings:
    return Settings()
