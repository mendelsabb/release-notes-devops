import os

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

# Nothing listens on port 1: connections fail immediately, simulating a DB outage.
UNREACHABLE_DB = "postgresql+psycopg://user:secret-password@127.0.0.1:1/none"


@pytest.fixture
def no_db_settings() -> Settings:
    return Settings(
        version="1.2.3",
        git_sha="abc1234def",
        environment="test",
        database_url=UNREACHABLE_DB,
        db_connect_timeout_s=1,
    )


@pytest.fixture
def no_db_client(no_db_settings: Settings):
    with TestClient(create_app(no_db_settings), raise_server_exceptions=False) as client:
        yield client


def database_url() -> str | None:
    url = os.environ.get("TEST_DATABASE_URL")
    if not url and os.environ.get("REQUIRE_DB") == "1":
        pytest.fail("REQUIRE_DB=1 but TEST_DATABASE_URL is not set")
    return url
