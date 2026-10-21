import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from psycopg import errors as pg_errors
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import Release
from app.observability import Metrics
from app.schemas import ReleaseCreate, ReleaseOut

log = logging.getLogger("release_notes.api")


def build_router(get_session, metrics: Metrics) -> APIRouter:
    router = APIRouter(prefix="/api/releases", tags=["releases"])
    SessionDep = Annotated[Session, Depends(get_session)]

    @router.get("", response_model=list[ReleaseOut])
    def list_releases(
        session: SessionDep,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ) -> list[Release]:
        # Newest first; id breaks ties so ordering is deterministic.
        stmt = select(Release).order_by(Release.released_at.desc(), Release.id.desc()).limit(limit)
        return list(session.scalars(stmt))

    @router.post("", response_model=ReleaseOut, status_code=status.HTTP_201_CREATED)
    def create_release(payload: ReleaseCreate, session: SessionDep) -> Release:
        release = Release(version=payload.version, description=payload.description)
        session.add(release)
        try:
            session.commit()
        except IntegrityError as exc:
            session.rollback()
            # Rely on the UNIQUE constraint rather than check-then-insert, which
            # would race under concurrent requests.
            if isinstance(exc.orig, pg_errors.UniqueViolation):
                log.info("duplicate release rejected", extra={"release_version": payload.version})
                raise HTTPException(
                    status.HTTP_409_CONFLICT, f"Release {payload.version!r} already exists"
                ) from None
            raise
        session.refresh(release)
        metrics.releases_created.inc()
        log.info("release recorded", extra={"release_version": release.version})
        return release

    return router
