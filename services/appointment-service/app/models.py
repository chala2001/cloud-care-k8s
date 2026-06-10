import enum
from sqlalchemy import Column, Integer, String, DateTime, Enum as SAEnum
from sqlalchemy.sql import func
from .database import Base


class AppointmentStatus(str, enum.Enum):
    scheduled = "scheduled"
    completed = "completed"
    cancelled = "cancelled"


class Appointment(Base):
    __tablename__ = "appointments"

    id            = Column(Integer, primary_key=True, index=True, autoincrement=True)
    patient_id    = Column(Integer, nullable=False, index=True)
    scheduled_for = Column(DateTime(timezone=True), nullable=False)
    reason        = Column(String(500), nullable=False)
    status        = Column(
        SAEnum(AppointmentStatus, name="appointment_status"),
        nullable=False,
        default=AppointmentStatus.scheduled,
    )
    created_at    = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)