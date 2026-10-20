import pytest
from pydantic import ValidationError

from app.schemas import ReleaseCreate


@pytest.mark.parametrize(
    "version", ["1.0.0", "v2", "2026.10.20", "1.4.0-rc.1", "1.4.0+build.7", "a" * 50]
)
def test_accepts_reasonable_versions(version):
    assert ReleaseCreate(version=version, description="x").version == version


@pytest.mark.parametrize(
    "version",
    ["", " ", "1.0 beta", ".1.0", "-1", "1/2", "a" * 51, "<script>", "1.0\t0"],
)
def test_rejects_malformed_versions(version):
    with pytest.raises(ValidationError):
        ReleaseCreate(version=version, description="x")


def test_strips_whitespace():
    release = ReleaseCreate(version="  1.0.0 ", description="  fixed login bug \n")
    assert release.version == "1.0.0"
    assert release.description == "fixed login bug"


@pytest.mark.parametrize("description", ["", "   ", "x" * 5001])
def test_rejects_empty_or_oversized_description(description):
    with pytest.raises(ValidationError):
        ReleaseCreate(version="1.0.0", description=description)


def test_rejects_unknown_fields():
    # Clients cannot set server-owned fields such as id or released_at.
    with pytest.raises(ValidationError):
        ReleaseCreate(version="1.0.0", description="x", id=5)
