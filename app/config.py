"""Runtime configuration, read once from environment variables.

Everything environment-specific (dev vs prod) is injected by the Helm chart;
the image itself only carries build metadata (APP_VERSION, GIT_SHA).
"""

import os
from dataclasses import dataclass, field

from sqlalchemy.engine import URL


def _bool(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    service_name: str = "release-notes"
    version: str = "dev"
    git_sha: str = "unknown"
    environment: str = "local"
    log_level: str = "INFO"

    # Either a full URL (tests, local dev) or discrete parts (Kubernetes).
    database_url: str | None = None
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "release_notes"
    db_user: str = "release_notes"
    db_password: str = field(default="", repr=False)

    # Small pool: 1 process per pod, 2-4 pods per environment, Postgres default
    # max_connections=100. Short timeouts so a dead DB fails fast instead of
    # piling up blocked worker threads.
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_pool_timeout_s: float = 3.0
    db_connect_timeout_s: int = 3
    db_statement_timeout_ms: int = 5000

    # Fault injection used only by the "broken rollout" demo image.
    simulate_unready: bool = False

    @property
    def sqlalchemy_url(self) -> URL | str:
        if self.database_url:
            return self.database_url
        # URL.create escapes the password correctly; it is never logged.
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        )

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        return cls(
            version=env.get("APP_VERSION", "dev"),
            git_sha=env.get("GIT_SHA", "unknown"),
            environment=env.get("APP_ENV", "local"),
            log_level=env.get("LOG_LEVEL", "INFO").upper(),
            database_url=env.get("DATABASE_URL") or None,
            db_host=env.get("DATABASE_HOST", "localhost"),
            db_port=int(env.get("DATABASE_PORT", "5432")),
            db_name=env.get("DATABASE_NAME", "release_notes"),
            db_user=env.get("DATABASE_USER", "release_notes"),
            db_password=env.get("DATABASE_PASSWORD", ""),
            db_pool_size=int(env.get("DB_POOL_SIZE", "5")),
            db_max_overflow=int(env.get("DB_MAX_OVERFLOW", "5")),
            simulate_unready=_bool(env.get("SIMULATE_UNREADY")),
        )
