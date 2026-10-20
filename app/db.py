from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings


def build_engine(settings: Settings) -> Engine:
    return create_engine(
        settings.sqlalchemy_url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=settings.db_pool_timeout_s,
        # Detect connections killed by a Postgres restart before handing them out.
        pool_pre_ping=True,
        pool_recycle=1800,
        connect_args={
            "connect_timeout": settings.db_connect_timeout_s,
            "options": f"-c statement_timeout={settings.db_statement_timeout_ms}",
            "application_name": settings.service_name,
        },
    )


def session_dependency(factory: sessionmaker[Session]):
    def get_session() -> Iterator[Session]:
        # Context manager guarantees the connection is returned to the pool
        # (and any open transaction rolled back) even when the handler raises.
        with factory() as session:
            yield session

    return get_session


def check_database(engine: Engine) -> None:
    """Raise if the database cannot serve the queries this app needs.

    Querying the real table (not just `SELECT 1`) also proves the migration ran.
    """
    with engine.connect() as conn:
        conn.execute(text("SELECT 1 FROM releases LIMIT 1"))
