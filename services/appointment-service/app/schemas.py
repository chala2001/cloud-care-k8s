from pydantic import BaseModel, Field
from datetime import datetime
from typing import Optional
from enum import Enum


class AppointmentStatus(str, Enum):
    scheduled = "scheduled"
    completed = "completed"
    cancelled = "cancelled"


class AppointmentIn(BaseModel):
    patient_id:    int      = Field(..., gt=0, description="ID of an existing patient")
    scheduled_for: datetime = Field(..., description="Appointment date and time (ISO 8601)")
    reason:        str      = Field(..., min_length=3, max_length=500,
                                    description="Reason for the appointment")
    status: AppointmentStatus = Field(
        default=AppointmentStatus.scheduled,
        description="One of: scheduled, completed, cancelled",
    )


class AppointmentOut(AppointmentIn):
    id:         int
    created_at: datetime

    class Config:
        from_attributes = True