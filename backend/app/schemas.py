from datetime import date, datetime, time
from enum import StrEnum
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class DurationUnit(StrEnum):
    hourly = "hourly"
    daily = "daily"


class BookingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    resource_id: str = Field(min_length=1, max_length=80, pattern=r"^[a-z0-9-]+$")
    date: date
    duration_unit: DurationUnit
    duration: float = Field(strict=True, ge=0.5, le=30, multiple_of=0.5)
    start_time: time | None = None

    @model_validator(mode="after")
    def validate_duration(self):
        if self.duration_unit == DurationUnit.hourly:
            if self.start_time is None:
                raise ValueError("start_time is required for hourly bookings")
            if self.duration > 24:
                raise ValueError("Hourly duration cannot exceed 24 hours")
            if self.start_time.tzinfo is not None:
                raise ValueError("start_time must be local time without an offset")
            if self.start_time.minute not in (0, 30) or self.start_time.second or self.start_time.microsecond:
                raise ValueError("start_time must be HH:00 or HH:30")
        else:
            if self.duration < 1 or not self.duration.is_integer():
                raise ValueError("Daily duration must be a whole number of days from 1 to 30")
            if self.start_time is not None:
                raise ValueError("Daily bookings start at midnight; omit start_time")
        return self


class ResourceOut(BaseModel):
    id: str
    name: str
    timezone: str
    allowed_units: list[DurationUnit]
    active: bool
    preferred_unit: DurationUnit
    hourly_start_step_minutes: int = 30
    hourly_duration_step_hours: float = 0.5
    max_hourly_duration: int = 24
    max_daily_duration: int = 30


class BookingOut(BaseModel):
    id: UUID
    resource_id: str
    user_id: str
    starts_at: datetime
    ends_at: datetime
    duration_unit: DurationUnit
    duration: float
    status: Literal["confirmed", "cancelled"]
    created_at: datetime
    cancelled_at: datetime | None


class AvailabilityOut(BaseModel):
    resource_id: str
    starts_at: datetime
    ends_at: datetime
    available: bool
