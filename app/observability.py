"""Structured JSON logging, Prometheus metrics and the per-request middleware."""

import json
import logging
import re
import time
import uuid
from contextvars import ContextVar
from datetime import UTC, datetime

from fastapi import FastAPI, Request
from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram
from starlette.responses import Response

from app.config import Settings

request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)

_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._\-]{1,64}$")
# Probe and scrape traffic is high-volume and uninteresting: DEBUG only.
_QUIET_ROUTES = {"/health", "/ready", "/metrics"}

# Attributes every LogRecord has; anything else was passed via `extra=` and is emitted.
# color_message is uvicorn's ANSI-coloured duplicate of message.
_STANDARD_ATTRS = set(vars(logging.makeLogRecord({}))) | {
    "message",
    "asctime",
    "taskName",
    "color_message",
}


class JsonFormatter(logging.Formatter):
    def __init__(self, settings: Settings):
        super().__init__()
        self._static = {
            "service": settings.service_name,
            "version": settings.version,
            "env": settings.environment,
        }

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": datetime.fromtimestamp(record.created, UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            **self._static,
        }
        if request_id := request_id_var.get():
            entry["request_id"] = request_id
        for key, value in vars(record).items():
            if key not in _STANDARD_ATTRS and not key.startswith("_"):
                entry[key] = value
        if record.exc_info:
            entry["exc_type"] = record.exc_info[0].__name__ if record.exc_info[0] else None
            entry["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def logging_config(settings: Settings) -> dict:
    """dictConfig used for both the app and uvicorn, so every line is JSON."""
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {"json": {"()": JsonFormatter, "settings": settings}},
        "handlers": {
            "stdout": {
                "class": "logging.StreamHandler",
                "formatter": "json",
                "stream": "ext://sys.stdout",
            }
        },
        "root": {"handlers": ["stdout"], "level": settings.log_level},
        "loggers": {
            "uvicorn": {"handlers": ["stdout"], "level": settings.log_level, "propagate": False},
            "uvicorn.error": {"level": settings.log_level},
            # We emit our own access log with route templates and request IDs.
            "uvicorn.access": {"handlers": [], "propagate": False},
            # Never let SQLAlchemy echo statements/parameters, even at DEBUG.
            "sqlalchemy": {"level": "WARNING"},
        },
    }


class Metrics:
    """Metric objects live on a per-app registry so tests can build many apps."""

    def __init__(self, settings: Settings):
        self.registry = CollectorRegistry()
        labels = ["method", "route", "status"]
        self.requests = Counter(
            "http_requests_total", "HTTP requests handled.", labels, registry=self.registry
        )
        self.latency = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency.",
            ["method", "route"],
            buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
            registry=self.registry,
        )
        self.in_progress = Gauge(
            "http_requests_in_progress",
            "HTTP requests currently being handled.",
            ["method"],
            registry=self.registry,
        )
        self.releases_created = Counter(
            "release_notes_releases_created_total",
            "Releases successfully recorded.",
            registry=self.registry,
        )
        info = Gauge(
            "release_notes_build_info",
            "Build metadata of the running process (always 1).",
            ["version", "git_sha"],
            registry=self.registry,
        )
        info.labels(settings.version, settings.git_sha).set(1)


def route_template(request: Request) -> str:
    # Use the matched route's template ("/api/releases"), never the raw path,
    # so label cardinality stays bounded no matter what clients request.
    route = request.scope.get("route")
    return getattr(route, "path", None) or "unmatched"


def install_middleware(app: FastAPI, settings: Settings, metrics: Metrics) -> None:
    log = logging.getLogger("release_notes.access")

    @app.middleware("http")
    async def observe(request: Request, call_next) -> Response:
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _SAFE_REQUEST_ID.match(incoming) else uuid.uuid4().hex
        token = request_id_var.set(request_id)
        method = request.method
        start = time.perf_counter()
        status = 500
        metrics.in_progress.labels(method).inc()
        try:
            response = await call_next(request)
            status = response.status_code
        finally:
            duration = time.perf_counter() - start
            route = route_template(request)
            metrics.in_progress.labels(method).dec()
            metrics.requests.labels(method, route, str(status)).inc()
            metrics.latency.labels(method, route).observe(duration)
            level = logging.INFO
            if route in _QUIET_ROUTES and status < 400:
                level = logging.DEBUG
            elif status >= 500:
                level = logging.ERROR
            log.log(
                level,
                "request handled",
                extra={
                    "method": method,
                    "route": route,
                    "path": request.url.path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                },
            )
            request_id_var.reset(token)

        response.headers["X-Request-ID"] = request_id
        response.headers["X-App-Version"] = settings.version
        return response
