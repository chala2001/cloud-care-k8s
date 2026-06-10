from sqlalchemy import Column, Integer, String, Date, DateTime
from sqlalchemy.sql import func
from .database import Base


class Patient(Base):
    __tablename__ = "patients"
    # Note: no __table_args__ schema here — the schema is set via search_path in database.py

    id          = Column(Integer, primary_key=True, index=True, autoincrement=True)
    full_name   = Column(String(200), nullable=False)
    date_of_birth = Column(Date, nullable=False)
    phone       = Column(String(20), nullable=False)
    created_at  = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)