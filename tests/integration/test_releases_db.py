"""API tests against a real PostgreSQL schema created by the Alembic migrations."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, text

from app.config import Settings
from app.main import create_app
from tests.conftest import database_url

pytestmark = pytest.mark.integration
ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def db_url(monkeypatch_module):
    url = database_url()
    if not url:
        pytest.skip("TEST_DATABASE_URL not set")
    # alembic/env.py reads the same env vars as the app.
    monkeypatch_module.setenv("DATABASE_URL", url)
    cfg = Config(str(ROOT / "alembic.ini"))
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    return url


@pytest.fixture(scope="module")
def monkeypatch_module():
    with pytest.MonkeyPatch.context() as mp:
        yield mp


@pytest.fixture
def engine(db_url):
    engine = create_engine(db_url)
    with engine.begin() as conn:
        conn.execute(text("TRUNCATE releases RESTART IDENTITY"))
    yield engine
    engine.dispose()


@pytest.fixture
def client(db_url, engine):
    settings = Settings(version="9.9.9", environment="test", database_url=db_url)
    with TestClient(create_app(settings)) as c:
        yield c


def test_migration_creates_expected_schema(engine):
    insp = inspect(engine)
    cols = {c["name"]: c for c in insp.get_columns("releases")}
    assert set(cols) == {"id", "version", "description", "released_at"}
    assert cols["version"]["nullable"] is False
    uniques = insp.get_unique_constraints("releases")
    assert any(u["column_names"] == ["version"] for u in uniques)


def test_create_and_list(client):
    resp = client.post("/api/releases", json={"version": "1.0.0", "description": "Initial"})
    assert resp.status_code == 201
    created = resp.json()
    assert created["version"] == "1.0.0"
    assert isinstance(created["id"], int)
    assert created["released_at"]

    listed = client.get("/api/releases").json()
    assert [r["version"] for r in listed] == ["1.0.0"]


def test_list_is_newest_first_and_deterministic(client, engine):
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO releases (version, description, released_at) VALUES "
                "('1.0.0', 'a', '2026-01-01T00:00:00Z'),"
                "('1.1.0', 'b', '2026-02-01T00:00:00Z'),"
                "('1.1.1', 'c', '2026-02-01T00:00:00Z')"  # same timestamp: id breaks the tie
            )
        )
    versions = [r["version"] for r in client.get("/api/releases").json()]
    assert versions == ["1.1.1", "1.1.0", "1.0.0"]
    assert [r["version"] for r in client.get("/api/releases?limit=1").json()] == ["1.1.1"]


def test_duplicate_version_is_409(client):
    body = {"version": "2.0.0", "description": "first"}
    assert client.post("/api/releases", json=body).status_code == 201
    dup = client.post("/api/releases", json={**body, "description": "second"})
    assert dup.status_code == 409
    assert "already exists" in dup.json()["detail"]
    assert len(client.get("/api/releases").json()) == 1


def test_concurrent_duplicates_yield_exactly_one_success(client):
    body = {"version": "3.0.0", "description": "race"}
    with ThreadPoolExecutor(max_workers=8) as pool:
        codes = sorted(
            pool.map(lambda _: client.post("/api/releases", json=body).status_code, range(8))
        )
    assert codes == [201] + [409] * 7


def test_data_survives_new_app_instance(db_url, client):
    client.post("/api/releases", json={"version": "4.0.0", "description": "persisted"})
    # A fresh app has its own engine/pool: the data must come from Postgres.
    with TestClient(create_app(Settings(database_url=db_url))) as other:
        assert [r["version"] for r in other.get("/api/releases").json()] == ["4.0.0"]


def test_readiness_with_database(client):
    assert client.get("/ready").json() == {"status": "ready"}


def test_readiness_fails_when_schema_missing(db_url, engine):
    # /ready queries the real table, so a DB that was never migrated is "not ready".
    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE releases RENAME TO releases_tmp"))
    try:
        with TestClient(create_app(Settings(database_url=db_url))) as c:
            assert c.get("/ready").status_code == 503
    finally:
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE releases_tmp RENAME TO releases"))


def test_release_metric_counts_successes_only(client):
    client.post("/api/releases", json={"version": "5.0.0", "description": "x"})
    client.post("/api/releases", json={"version": "5.0.0", "description": "x"})
    text_ = client.get("/metrics").text
    assert "release_notes_releases_created_total 1.0" in text_
    assert 'route="/api/releases",status="409"' in text_
