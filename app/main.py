import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy.exc import OperationalError
from sqlalchemy.exc import TimeoutError as PoolTimeoutError
from sqlalchemy.orm import sessionmaker
from starlette.responses import Response

from app.api import build_router
from app.config import Settings
from app.db import build_engine, check_database, session_dependency
from app.observability import Metrics, install_middleware, request_id_var
from app.schemas import VersionInfo

STATIC_DIR = Path(__file__).parent / "static"
log = logging.getLogger("release_notes")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = build_engine(settings)  # lazy: no connection is opened here
    session_factory = sessionmaker(engine, expire_on_commit=False)
    metrics = Metrics(settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        log.info("starting", extra={"git_sha": settings.git_sha})
        yield
        # Runs after uvicorn has drained in-flight requests on SIGTERM.
        engine.dispose()
        log.info("stopped")

    app = FastAPI(
        title="Release Notes",
        version=settings.version,
        lifespan=lifespan,
        docs_url="/api/docs",
        openapi_url="/api/openapi.json",
        redoc_url=None,
    )
    app.state.settings = settings
    app.state.engine = engine
    install_middleware(app, settings, metrics)
    app.include_router(build_router(session_dependency(session_factory), metrics))

    @app.exception_handler(OperationalError)
    @app.exception_handler(PoolTimeoutError)
    async def database_unavailable(request: Request, exc: Exception) -> JSONResponse:
        # Log the exception type only: driver messages can include host/user details.
        log.error("database unavailable", extra={"error": type(exc).__name__})
        return JSONResponse(
            status_code=503,
            content={"detail": "Database unavailable", "request_id": request_id_var.get()},
            headers={"Retry-After": "5"},
        )

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled error")
        return JSONResponse(
            status_code=500,
            content={"detail": "Internal server error", "request_id": request_id_var.get()},
        )

    @app.get("/health", tags=["ops"])
    def health() -> dict:
        # Liveness: the process is up and serving. Deliberately ignores the
        # database so a Postgres outage does not trigger restart loops.
        return {"status": "ok"}

    @app.get("/ready", tags=["ops"])
    async def ready() -> JSONResponse:
        if settings.simulate_unready:
            return JSONResponse({"status": "unavailable", "reason": "simulated"}, 503)
        try:
            await run_in_threadpool(check_database, engine)
        except Exception as exc:
            log.warning("readiness check failed", extra={"error": type(exc).__name__})
            return JSONResponse({"status": "unavailable", "reason": "database"}, 503)
        return JSONResponse({"status": "ready"})

    @app.get("/version", response_model=VersionInfo, tags=["ops"])
    def version() -> VersionInfo:
        return VersionInfo(
            service=settings.service_name,
            version=settings.version,
            git_sha=settings.git_sha,
            environment=settings.environment,
        )

    @app.get("/metrics", include_in_schema=False)
    def prometheus_metrics() -> Response:
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/", include_in_schema=False)
    def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-cache"})

    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
    return app
