"""Container entrypoint: `python -m app`.

Running uvicorn programmatically lets us hand it our JSON logging config and
the graceful-shutdown timeout. On SIGTERM uvicorn stops accepting connections,
lets in-flight requests finish (up to GRACEFUL_TIMEOUT seconds), then runs the
lifespan shutdown which closes the DB pool.
"""

import os

import uvicorn

from app.config import Settings
from app.main import create_app
from app.observability import logging_config


def main() -> None:
    settings = Settings.from_env()
    uvicorn.run(
        create_app(settings),
        host="0.0.0.0",  # noqa: S104 - must listen on the pod IP
        port=int(os.environ.get("PORT", "8000")),
        log_config=logging_config(settings),
        access_log=False,
        proxy_headers=False,
        server_header=False,
        timeout_graceful_shutdown=int(os.environ.get("GRACEFUL_TIMEOUT", "20")),
    )


if __name__ == "__main__":
    main()
