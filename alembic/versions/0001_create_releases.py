"""create releases table

Revision ID: 0001
Revises:
Create Date: 2026-10-20
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "releases",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), primary_key=True),
        sa.Column("version", sa.String(50), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column(
            "released_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.UniqueConstraint("version", name="uq_releases_version"),
    )
    # Supports the list endpoint's ORDER BY released_at DESC, id DESC.
    op.create_index("ix_releases_released_at_id", "releases", ["released_at", "id"])


def downgrade() -> None:
    op.drop_index("ix_releases_released_at_id", table_name="releases")
    op.drop_table("releases")
