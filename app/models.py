from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Identity, Index, String, Text, UniqueConstraint, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Release(Base):
    __tablename__ = "releases"
    # Names match alembic/versions/0001 so autogenerate sees no drift.
    __table_args__ = (
        UniqueConstraint("version", name="uq_releases_version"),
        Index("ix_releases_released_at_id", "released_at", "id"),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    # Uniqueness is enforced by Postgres; the API maps the violation to 409.
    version: Mapped[str] = mapped_column(String(50), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    released_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
