# syntax=docker/dockerfile:1.7

# ---- build stage: resolve and install locked dependencies into a venv ----------
FROM python:3.12.15-slim AS build

COPY --from=ghcr.io/astral-sh/uv:0.12.6 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src
# Dependency layer: only invalidated when the lockfile changes, not on code edits.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# ---- runtime stage: just the interpreter, the venv and the app -----------------
# No uv, compilers or package caches end up here.
FROM python:3.12.15-slim AS runtime

ARG APP_VERSION=dev
ARG GIT_SHA=unknown
# Bakes a fault into the image for the failed-rollout demo only (see scripts/).
ARG SIMULATE_UNREADY=false

LABEL org.opencontainers.image.title="release-notes" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    SIMULATE_UNREADY=${SIMULATE_UNREADY}

WORKDIR /srv
COPY --from=build /opt/venv /opt/venv
# Root-owned and not writable by the app user; the root FS is also mounted
# read-only in Kubernetes.
COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
RUN python -m compileall -q app alembic

USER 10001:10001
EXPOSE 8000
# Exec form: python is PID 1 and receives SIGTERM directly; uvicorn handles it
# by draining in-flight requests (see app/__main__.py).
CMD ["python", "-m", "app"]
