from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field

# Starts with an alphanumeric, then letters, digits and . _ + -  (covers SemVer,
# CalVer and build metadata such as 1.4.0+build.7). Max length matches the column.
VERSION_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._+\-]{0,49}$"

Version = Annotated[str, Field(min_length=1, max_length=50, pattern=VERSION_PATTERN)]
Description = Annotated[str, Field(min_length=1, max_length=5000)]


class ReleaseCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    version: Version
    description: Description


class ReleaseOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    version: str
    description: str
    released_at: datetime


class VersionInfo(BaseModel):
    service: str
    version: str
    git_sha: str
    environment: str
