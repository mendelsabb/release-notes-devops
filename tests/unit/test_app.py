"""Behaviour that does not need a working database (DB deliberately unreachable)."""

import json
import logging

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.observability import JsonFormatter, logging_config


def test_liveness_ignores_database(no_db_client):
    assert no_db_client.get("/health").json() == {"status": "ok"}


def test_readiness_reports_database_outage(no_db_client):
    resp = no_db_client.get("/ready")
    assert resp.status_code == 503
    assert resp.json() == {"status": "unavailable", "reason": "database"}


def test_simulated_unready_flag(no_db_settings):
    settings = Settings(**{**no_db_settings.__dict__, "simulate_unready": True})
    with TestClient(create_app(settings)) as client:
        assert client.get("/ready").status_code == 503
        assert client.get("/health").status_code == 200


def test_api_returns_503_without_leaking_details(no_db_client):
    for resp in (
        no_db_client.get("/api/releases"),
        no_db_client.post("/api/releases", json={"version": "1.0.0", "description": "x"}),
    ):
        assert resp.status_code == 503
        assert resp.headers["Retry-After"] == "5"
        body = resp.text
        assert "secret-password" not in body and "127.0.0.1" not in body
        assert resp.json()["detail"] == "Database unavailable"


def test_validation_errors_are_422(no_db_client):
    resp = no_db_client.post("/api/releases", json={"version": "has space", "description": "x"})
    assert resp.status_code == 422
    assert no_db_client.get("/api/releases?limit=0").status_code == 422
    assert no_db_client.get("/api/releases?limit=201").status_code == 422


def test_version_endpoint_and_header(no_db_client):
    resp = no_db_client.get("/version")
    assert resp.json() == {
        "service": "release-notes",
        "version": "1.2.3",
        "git_sha": "abc1234def",
        "environment": "test",
    }
    assert resp.headers["X-App-Version"] == "1.2.3"


def test_request_id_propagation(no_db_client):
    assert (
        no_db_client.get("/health", headers={"X-Request-ID": "abc-123"}).headers["X-Request-ID"]
        == "abc-123"
    )
    # Unsafe IDs (log injection, unbounded length) are replaced, not echoed.
    replaced = no_db_client.get("/health", headers={"X-Request-ID": "bad id\nINJECTED"})
    assert replaced.headers["X-Request-ID"] != "bad id\nINJECTED"
    assert len(replaced.headers["X-Request-ID"]) == 32


def test_metrics_use_route_templates_not_raw_paths(no_db_client):
    no_db_client.get("/health")
    no_db_client.get("/no/such/path/12345")
    text = no_db_client.get("/metrics").text
    assert 'http_requests_total{method="GET",route="/health",status="200"} 1.0' in text
    assert 'route="unmatched",status="404"' in text
    assert "12345" not in text
    assert 'release_notes_build_info{git_sha="abc1234def",version="1.2.3"} 1.0' in text
    assert "http_request_duration_seconds_bucket" in text


def test_ui_is_served(no_db_client):
    resp = no_db_client.get("/")
    assert resp.status_code == 200
    assert "Release Notes" in resp.text
    assert no_db_client.get("/static/app.js").status_code == 200


def test_access_log_is_structured(no_db_settings, caplog):
    caplog.set_level(logging.INFO, logger="release_notes.access")
    with TestClient(create_app(no_db_settings)) as client:
        client.get("/version", headers={"X-Request-ID": "req-1"})
    record = next(r for r in caplog.records if r.name == "release_notes.access")
    line = json.loads(JsonFormatter(no_db_settings).format(record))
    assert line["level"] == "INFO"
    assert line["route"] == "/version"
    assert line["status"] == 200
    assert line["method"] == "GET"
    assert line["version"] == "1.2.3"
    assert line["env"] == "test"
    assert isinstance(line["duration_ms"], float)


def test_probe_requests_log_at_debug(no_db_settings, caplog):
    caplog.set_level(logging.DEBUG, logger="release_notes.access")
    with TestClient(create_app(no_db_settings)) as client:
        client.get("/health")
    record = next(r for r in caplog.records if r.name == "release_notes.access")
    assert record.levelno == logging.DEBUG


def test_password_is_never_rendered(no_db_settings):
    settings = Settings(db_password="hunter2-secret")
    assert "hunter2-secret" not in repr(settings)
    assert "hunter2-secret" not in str(settings.sqlalchemy_url)  # SQLAlchemy masks it
    config = json.dumps(logging_config(settings), default=str)
    assert "hunter2-secret" not in config


def test_exceptions_are_logged_as_json(no_db_settings):
    try:
        raise ValueError("boom")
    except ValueError:
        record = logging.getLogger("x").makeRecord(
            "x", logging.ERROR, __file__, 1, "failed", None, exc_info=__import__("sys").exc_info()
        )
    line = json.loads(JsonFormatter(no_db_settings).format(record))
    assert line["exc_type"] == "ValueError"
    assert "boom" in line["exc_info"]
