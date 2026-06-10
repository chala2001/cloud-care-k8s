from pydantic import BaseModel, Field
from datetime import date, datetime
from typing import Optional


class PatientIn(BaseModel):
    """Fields required when creating or updating a patient."""
    full_name: str = Field(..., min_length=2, max_length=200,
                           description="Patient's full name")
    date_of_birth: date = Field(...,
                                description="Date of birth in YYYY-MM-DD format")
    phone: str = Field(..., min_length=7, max_length=20,
                       description="Contact phone number")


class PatientOut(PatientIn):
    """Fields returned when reading a patient — includes server-generated fields."""
    id: int
    created_at: datetime

    class Config:
        from_attributes = True   # allows SQLAlchemy models to be converted directly