from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, text

from app.config import Settings
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Arbitrary constant: serialises concurrent `alembic upgrade` runs (e.g. a retried
# Job overlapping a previous attempt) on the database itself.
MIGRATION_LOCK_ID = 7_310_552


def run_migrations_online() -> None:
    settings = Settings.from_env()
    engine = create_engine(
        settings.sqlalchemy_url, connect_args={"connect_timeout": settings.db_connect_timeout_s}
    )
    with engine.connect() as connection:
        connection.execute(text("SELECT pg_advisory_lock(:id)"), {"id": MIGRATION_LOCK_ID})
        connection.commit()
        try:
            context.configure(connection=connection, target_metadata=Base.metadata)
            with context.begin_transaction():
                context.run_migrations()
        finally:
            connection.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": MIGRATION_LOCK_ID})
            connection.commit()
    engine.dispose()


if context.is_offline_mode():
    raise SystemExit("Offline mode is not supported; run against a database.")
run_migrations_online()
