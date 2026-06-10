# 02 — Microservices Split: Write the Code

> **Goal of this doc:** write every single Python file for all four microservices,
> understand why each boundary was drawn where it was, and run everything together
> with Docker Compose to verify inter-service communication works before touching
> Kubernetes at all.

By the end of this doc you will have:
- All four services fully coded with complete files
- A working `docker-compose.yml` and `init.sql`
- All services running and talking to each other locally
- Tests passing for every service

---

## 1. Why We Split the Monolith

In CloudCare v1, the entire backend was one FastAPI app — one Python process, one Docker
image, one deployment. It worked, but had real problems:

- To fix a bug in appointments, you redeploy **everything** — including patient and audit
  code that hasn't changed.
- If notification sends thousands of emails and crashes, patient queries go down too —
  they share the same process.
- You cannot scale appointment-service independently from patient-service.
- One CI/CD pipeline deploys everything or nothing.

**Microservices** solve this by making each concern an independent deployable unit:
its own codebase, Docker image, database, CI/CD pipeline, and scaling policy.

```
v1 monolith                        v2 microservices
────────────────────               ──────────────────────────────────────
One FastAPI app                    patient-service      (port 8001)
  /patients    → RDS               appointment-service  (port 8002)
  /appointments → RDS              audit-service        (port 8003)
  /audit       → DynamoDB          notification-service (port 8004)
  /notify      → SES
```

The golden rule: **a service owns its data. No other service touches its database.**

---

## 2. Directory Structure to Create

Before writing any code, create this folder structure:

```bash
mkdir -p services/patient-service/app
mkdir -p services/patient-service/tests
mkdir -p services/appointment-service/app
mkdir -p services/appointment-service/tests
mkdir -p services/audit-service/app
mkdir -p services/audit-service/tests
mkdir -p services/notification-service/app
mkdir -p services/notification-service/tests
touch services/patient-service/app/__init__.py
touch services/patient-service/tests/__init__.py
touch services/appointment-service/app/__init__.py
touch services/appointment-service/tests/__init__.py
touch services/audit-service/app/__init__.py
touch services/audit-service/tests/__init__.py
touch services/notification-service/app/__init__.py
touch services/notification-service/tests/__init__.py
```

Final structure:
```
services/
├── docker-compose.yml
├── init.sql
├── patient-service/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py
│   │   ├── database.py
│   │   ├── models.py
│   │   └── schemas.py
│   ├── tests/
│   │   ├── __init__.py
│   │   └── test_patients.py
│   ├── Dockerfile
│   └── requirements.txt
├── appointment-service/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py
│   │   ├── database.py
│   │   ├── models.py
│   │   └── schemas.py
│   ├── tests/
│   │   ├── __init__.py
│   │   └── test_appointments.py
│   ├── Dockerfile
│   └── requirements.txt
├── audit-service/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py
│   │   └── schemas.py
│   ├── tests/
│   │   ├── __init__.py
│   │   └── test_audit.py
│   ├── Dockerfile
│   └── requirements.txt
└── notification-service/
    ├── app/
    │   ├── __init__.py
    │   ├── main.py
    │   └── schemas.py
    ├── tests/
    │   ├── __init__.py
    │   └── test_notification.py
    ├── Dockerfile
    └── requirements.txt
```

---

## 3. Database Schema Isolation

All four services share one RDS PostgreSQL instance (free-tier eligible), but each
service connects with its own database user that can only see its own schema.

```
PostgreSQL instance
└── Database: cloudcare
    ├── Schema: patients       ← only patient_svc user can access this
    └── Schema: appointments   ← only appt_svc user can access this

DynamoDB table: audit_events   ← only audit-service has write permission (via IRSA)
```

The `init.sql` file creates these schemas and users when the database container first
starts.

### `services/init.sql`

Create this file at `services/init.sql`:

```sql
-- ──────────────────────────────────────────────────────────────────────────────
-- CloudCare-K8s database initialisation
-- Runs automatically when the postgres container starts for the first time.
-- ──────────────────────────────────────────────────────────────────────────────

-- 1. Create the two schemas
CREATE SCHEMA IF NOT EXISTS patients;
CREATE SCHEMA IF NOT EXISTS appointments;

-- 2. Create per-service database users
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'patient_svc') THEN
    CREATE USER patient_svc WITH PASSWORD 'patient_pass';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'appt_svc') THEN
    CREATE USER appt_svc WITH PASSWORD 'appt_pass';
  END IF;
END
$$;

-- 3. Grant patient_svc access to patients schema ONLY
GRANT USAGE  ON SCHEMA patients TO patient_svc;
GRANT CREATE ON SCHEMA patients TO patient_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA patients
  GRANT ALL ON TABLES    TO patient_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA patients
  GRANT ALL ON SEQUENCES TO patient_svc;
-- Also grant on any tables that already exist (re-runs are safe)
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA patients TO patient_svc;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA patients TO patient_svc;

-- 4. Grant appt_svc access to appointments schema ONLY
GRANT USAGE  ON SCHEMA appointments TO appt_svc;
GRANT CREATE ON SCHEMA appointments TO appt_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA appointments
  GRANT ALL ON TABLES    TO appt_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA appointments
  GRANT ALL ON SEQUENCES TO appt_svc;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA appointments TO appt_svc;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA appointments TO appt_svc;

-- 5. Explicitly revoke cross-schema access
REVOKE ALL ON SCHEMA appointments FROM patient_svc;
REVOKE ALL ON SCHEMA patients     FROM appt_svc;
```

---

## 4. patient-service — Complete Code

**What it does:** full CRUD for patient records. It also fires audit events to
`audit-service` after every create/update/delete.

### `services/patient-service/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.30.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
pydantic[email]==2.7.1
httpx==0.27.0
prometheus-fastapi-instrumentator==6.1.0
pytest==8.2.0
pytest-asyncio==0.23.6
```

### `services/patient-service/app/__init__.py`

```python
# empty — marks this directory as a Python package
```

### `services/patient-service/app/schemas.py`

```python
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
```

> 🧠 **Why two schemas (PatientIn vs PatientOut)?**
> `PatientIn` is what the caller sends — no `id` or `created_at` because the database
> generates those. `PatientOut` is what we return — includes the generated fields.
> Keeping them separate prevents callers from injecting an `id` or `created_at`.

### `services/patient-service/app/models.py`

```python
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
```

### `services/patient-service/app/database.py`

```python
import os
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = os.environ["DATABASE_URL"]
DB_SCHEMA    = os.environ.get("DB_SCHEMA", "patients")

# connect_args is only needed for SQLite (used in tests)
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_engine(DATABASE_URL, connect_args=connect_args)


@event.listens_for(engine, "connect")
def set_search_path(dbapi_conn, connection_record):
    """
    Set the PostgreSQL search_path to our service's schema on every new connection.
    This means every query automatically targets the 'patients' schema without
    needing to prefix table names.
    SQLite does not support schemas, so we skip this for test connections.
    """
    if DATABASE_URL.startswith("sqlite"):
        return
    cursor = dbapi_conn.cursor()
    cursor.execute(f"SET search_path TO {DB_SCHEMA}")
    cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    """FastAPI dependency — yields a database session and closes it after the request."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def create_tables():
    """Create all tables defined by SQLAlchemy models. Called at startup."""
    Base.metadata.create_all(bind=engine)
```

### `services/patient-service/app/main.py`

```python
import os
import logging
import httpx
from fastapi import FastAPI, Depends, HTTPException, BackgroundTasks
from sqlalchemy.orm import Session

from . import models, schemas
from .database import get_db, create_tables

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("patient-service")

app = FastAPI(
    title="patient-service",
    description="Manages patient records for CloudCare-K8s",
    version="1.0.0",
)

AUDIT_SERVICE_URL = os.environ.get("AUDIT_SERVICE_URL", "http://audit-service:8003")


@app.on_event("startup")
def startup():
    """Create tables on startup (idempotent — safe to run every time)."""
    create_tables()
    logger.info("patient-service started, tables ready")


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health", tags=["health"])
def health():
    return {"status": "ok", "service": "patient-service"}


# ── Internal helper ───────────────────────────────────────────────────────────

async def fire_audit(entity_id: int, action: str):
    """
    Send a fire-and-forget audit event. We use a background task so the caller
    never waits for the audit call. If audit-service is down, we log and move on
    — an audit failure must never fail a patient operation.
    """
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            await client.post(f"{AUDIT_SERVICE_URL}/audit", json={
                "entity_type": "patient",
                "entity_id":   str(entity_id),
                "action":      action,
                "actor":       "patient-service",
            })
    except Exception as exc:
        logger.warning("audit event failed (non-critical): %s", exc)


# ── CRUD routes ───────────────────────────────────────────────────────────────

@app.post("/patients", response_model=schemas.PatientOut, status_code=201, tags=["patients"])
async def create_patient(
    patient: schemas.PatientIn,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    db_patient = models.Patient(**patient.model_dump())
    db.add(db_patient)
    db.commit()
    db.refresh(db_patient)
    background_tasks.add_task(fire_audit, db_patient.id, "created")
    logger.info("created patient id=%d", db_patient.id)
    return db_patient


@app.get("/patients", response_model=list[schemas.PatientOut], tags=["patients"])
def list_patients(
    skip: int = 0,
    limit: int = 100,
    db: Session = Depends(get_db),
):
    return db.query(models.Patient).offset(skip).limit(limit).all()


@app.get("/patients/{patient_id}", response_model=schemas.PatientOut, tags=["patients"])
def get_patient(patient_id: int, db: Session = Depends(get_db)):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail=f"Patient {patient_id} not found")
    return patient


@app.put("/patients/{patient_id}", response_model=schemas.PatientOut, tags=["patients"])
async def update_patient(
    patient_id: int,
    data: schemas.PatientIn,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail=f"Patient {patient_id} not found")
    for field, value in data.model_dump().items():
        setattr(patient, field, value)
    db.commit()
    db.refresh(patient)
    background_tasks.add_task(fire_audit, patient.id, "updated")
    logger.info("updated patient id=%d", patient.id)
    return patient


@app.delete("/patients/{patient_id}", status_code=204, tags=["patients"])
async def delete_patient(
    patient_id: int,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail=f"Patient {patient_id} not found")
    db.delete(patient)
    db.commit()
    background_tasks.add_task(fire_audit, patient_id, "deleted")
    logger.info("deleted patient id=%d", patient_id)
```

### `services/patient-service/tests/__init__.py`

```python
# empty
```

### `services/patient-service/tests/test_patients.py`

```python
"""
Tests for patient-service.

We use SQLite in-memory so no PostgreSQL is needed to run tests.
The DATABASE_URL env var is set before importing the app.
"""
import os
os.environ.setdefault("DATABASE_URL", "sqlite:///./test_patients.db")
os.environ.setdefault("DB_SCHEMA", "main")
os.environ.setdefault("AUDIT_SERVICE_URL", "http://localhost:9999")  # not real — won't be called

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.main import app
from app.database import Base, get_db

# ── Test database setup ────────────────────────────────────────────────────────
TEST_DATABASE_URL = "sqlite:///./test_patients.db"
test_engine = create_engine(TEST_DATABASE_URL, connect_args={"check_same_thread": False})
TestSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=test_engine)


def override_get_db():
    db = TestSessionLocal()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db


@pytest.fixture(autouse=True)
def reset_db():
    """Create tables before each test, drop after."""
    Base.metadata.create_all(bind=test_engine)
    yield
    Base.metadata.drop_all(bind=test_engine)


client = TestClient(app)


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_create_patient():
    r = client.post("/patients", json={
        "full_name": "Nimal Silva",
        "date_of_birth": "1985-03-15",
        "phone": "0771234567",
    })
    assert r.status_code == 201
    body = r.json()
    assert body["full_name"] == "Nimal Silva"
    assert body["date_of_birth"] == "1985-03-15"
    assert body["phone"] == "0771234567"
    assert "id" in body
    assert "created_at" in body


def test_list_patients_empty():
    r = client.get("/patients")
    assert r.status_code == 200
    assert r.json() == []


def test_list_patients_after_create():
    client.post("/patients", json={
        "full_name": "Kamala Perera",
        "date_of_birth": "1990-07-22",
        "phone": "0712345678",
    })
    r = client.get("/patients")
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_get_patient():
    create_r = client.post("/patients", json={
        "full_name": "Sunil Fernando",
        "date_of_birth": "1978-11-30",
        "phone": "0751234567",
    })
    patient_id = create_r.json()["id"]
    r = client.get(f"/patients/{patient_id}")
    assert r.status_code == 200
    assert r.json()["id"] == patient_id


def test_get_patient_not_found():
    r = client.get("/patients/99999")
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()


def test_update_patient():
    create_r = client.post("/patients", json={
        "full_name": "Old Name",
        "date_of_birth": "2000-01-01",
        "phone": "0700000000",
    })
    patient_id = create_r.json()["id"]
    r = client.put(f"/patients/{patient_id}", json={
        "full_name": "New Name",
        "date_of_birth": "2000-01-01",
        "phone": "0711111111",
    })
    assert r.status_code == 200
    assert r.json()["full_name"] == "New Name"
    assert r.json()["phone"] == "0711111111"


def test_update_patient_not_found():
    r = client.put("/patients/99999", json={
        "full_name": "Ghost",
        "date_of_birth": "2000-01-01",
        "phone": "0700000000",
    })
    assert r.status_code == 404


def test_delete_patient():
    create_r = client.post("/patients", json={
        "full_name": "Delete Me",
        "date_of_birth": "1999-05-05",
        "phone": "0699999999",
    })
    patient_id = create_r.json()["id"]
    r = client.delete(f"/patients/{patient_id}")
    assert r.status_code == 204
    # Confirm it's gone
    r2 = client.get(f"/patients/{patient_id}")
    assert r2.status_code == 404


def test_delete_patient_not_found():
    r = client.delete("/patients/99999")
    assert r.status_code == 404


def test_create_patient_validation_fails():
    # full_name too short
    r = client.post("/patients", json={
        "full_name": "A",
        "date_of_birth": "1990-01-01",
        "phone": "077",
    })
    assert r.status_code == 422
```

### `services/patient-service/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install dependencies first (layer caching — only rebuilds if requirements.txt changes)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ app/

EXPOSE 8001

# Use uvicorn with one worker per container (Kubernetes handles horizontal scaling)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
```

---

## 5. appointment-service — Complete Code

**What it does:** full CRUD for appointments. Calls patient-service to verify a patient
exists before creating an appointment. Also fires audit events and sends notifications.

### `services/appointment-service/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.30.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
pydantic[email]==2.7.1
httpx==0.27.0
prometheus-fastapi-instrumentator==6.1.0
pytest==8.2.0
pytest-asyncio==0.23.6
respx==0.21.1
```

> `respx` is a library for mocking `httpx` calls in tests — used to fake
> the patient-service and audit-service responses without running those services.

### `services/appointment-service/app/__init__.py`

```python
# empty
```

### `services/appointment-service/app/schemas.py`

```python
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
```

### `services/appointment-service/app/models.py`

```python
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
```

### `services/appointment-service/app/database.py`

```python
import os
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = os.environ["DATABASE_URL"]
DB_SCHEMA    = os.environ.get("DB_SCHEMA", "appointments")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)


@event.listens_for(engine, "connect")
def set_search_path(dbapi_conn, connection_record):
    if DATABASE_URL.startswith("sqlite"):
        return
    cursor = dbapi_conn.cursor()
    cursor.execute(f"SET search_path TO {DB_SCHEMA}")
    cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def create_tables():
    Base.metadata.create_all(bind=engine)
```

### `services/appointment-service/app/main.py`

```python
import os
import logging
import httpx
from fastapi import FastAPI, Depends, HTTPException, BackgroundTasks
from sqlalchemy.orm import Session

from . import models, schemas
from .database import get_db, create_tables

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("appointment-service")

app = FastAPI(
    title="appointment-service",
    description="Manages appointments for CloudCare-K8s",
    version="1.0.0",
)

PATIENT_SERVICE_URL      = os.environ.get("PATIENT_SERVICE_URL",      "http://patient-service:8001")
AUDIT_SERVICE_URL        = os.environ.get("AUDIT_SERVICE_URL",        "http://audit-service:8003")
NOTIFICATION_SERVICE_URL = os.environ.get("NOTIFICATION_SERVICE_URL", "http://notification-service:8004")


@app.on_event("startup")
def startup():
    create_tables()
    logger.info("appointment-service started, tables ready")


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health", tags=["health"])
def health():
    return {"status": "ok", "service": "appointment-service"}


# ── Internal helpers ──────────────────────────────────────────────────────────

async def verify_patient_exists(patient_id: int) -> None:
    """
    Calls patient-service to confirm the patient exists.
    Raises HTTPException if not found or if patient-service is unreachable.
    """
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{PATIENT_SERVICE_URL}/patients/{patient_id}")
    except httpx.RequestError as exc:
        logger.error("could not reach patient-service: %s", exc)
        raise HTTPException(status_code=503, detail="patient-service is unreachable")

    if resp.status_code == 404:
        raise HTTPException(status_code=422, detail=f"Patient {patient_id} does not exist")
    if resp.status_code != 200:
        raise HTTPException(status_code=503, detail="patient-service returned an unexpected error")


async def fire_audit(entity_id: int, action: str, patient_id: int):
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            await client.post(f"{AUDIT_SERVICE_URL}/audit", json={
                "entity_type": "appointment",
                "entity_id":   str(entity_id),
                "action":      action,
                "actor":       "appointment-service",
                "metadata":    {"patient_id": patient_id},
            })
    except Exception as exc:
        logger.warning("audit event failed (non-critical): %s", exc)


async def fire_notification(appointment: models.Appointment):
    """Notify patient of a new appointment. Failures are non-critical."""
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            await client.post(f"{NOTIFICATION_SERVICE_URL}/notify", json={
                "to":      "patient@example.com",  # in production, look up from patient-service
                "subject": "Appointment Confirmed",
                "body":    f"Your appointment on {appointment.scheduled_for} has been confirmed.\nReason: {appointment.reason}",
            })
    except Exception as exc:
        logger.warning("notification failed (non-critical): %s", exc)


# ── CRUD routes ───────────────────────────────────────────────────────────────

@app.post("/appointments", response_model=schemas.AppointmentOut, status_code=201,
          tags=["appointments"])
async def create_appointment(
    appt: schemas.AppointmentIn,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    # Validate patient exists — this is the key inter-service call
    await verify_patient_exists(appt.patient_id)

    db_appt = models.Appointment(**appt.model_dump())
    db.add(db_appt)
    db.commit()
    db.refresh(db_appt)

    background_tasks.add_task(fire_audit, db_appt.id, "created", db_appt.patient_id)
    background_tasks.add_task(fire_notification, db_appt)

    logger.info("created appointment id=%d for patient_id=%d", db_appt.id, db_appt.patient_id)
    return db_appt


@app.get("/appointments", response_model=list[schemas.AppointmentOut], tags=["appointments"])
def list_appointments(
    skip: int = 0,
    limit: int = 100,
    patient_id: int = None,
    db: Session = Depends(get_db),
):
    query = db.query(models.Appointment)
    if patient_id is not None:
        query = query.filter(models.Appointment.patient_id == patient_id)
    return query.offset(skip).limit(limit).all()


@app.get("/appointments/{appointment_id}", response_model=schemas.AppointmentOut,
         tags=["appointments"])
def get_appointment(appointment_id: int, db: Session = Depends(get_db)):
    appt = db.query(models.Appointment).filter(
        models.Appointment.id == appointment_id).first()
    if not appt:
        raise HTTPException(status_code=404, detail=f"Appointment {appointment_id} not found")
    return appt


@app.put("/appointments/{appointment_id}", response_model=schemas.AppointmentOut,
         tags=["appointments"])
async def update_appointment(
    appointment_id: int,
    data: schemas.AppointmentIn,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    appt = db.query(models.Appointment).filter(
        models.Appointment.id == appointment_id).first()
    if not appt:
        raise HTTPException(status_code=404, detail=f"Appointment {appointment_id} not found")

    # If patient_id changed, verify the new patient exists
    if data.patient_id != appt.patient_id:
        await verify_patient_exists(data.patient_id)

    for field, value in data.model_dump().items():
        setattr(appt, field, value)
    db.commit()
    db.refresh(appt)

    background_tasks.add_task(fire_audit, appt.id, "updated", appt.patient_id)
    logger.info("updated appointment id=%d", appt.id)
    return appt


@app.delete("/appointments/{appointment_id}", status_code=204, tags=["appointments"])
async def delete_appointment(
    appointment_id: int,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    appt = db.query(models.Appointment).filter(
        models.Appointment.id == appointment_id).first()
    if not appt:
        raise HTTPException(status_code=404, detail=f"Appointment {appointment_id} not found")
    patient_id = appt.patient_id
    db.delete(appt)
    db.commit()
    background_tasks.add_task(fire_audit, appointment_id, "deleted", patient_id)
    logger.info("deleted appointment id=%d", appointment_id)
```

### `services/appointment-service/tests/__init__.py`

```python
# empty
```

### `services/appointment-service/tests/test_appointments.py`

```python
"""
Tests for appointment-service.
Uses SQLite + respx to mock the patient-service HTTP calls.
"""
import os
os.environ.setdefault("DATABASE_URL",           "sqlite:///./test_appointments.db")
os.environ.setdefault("DB_SCHEMA",              "main")
os.environ.setdefault("PATIENT_SERVICE_URL",    "http://patient-service-mock:8001")
os.environ.setdefault("AUDIT_SERVICE_URL",      "http://audit-mock:8003")
os.environ.setdefault("NOTIFICATION_SERVICE_URL", "http://notify-mock:8004")

import pytest
import respx
import httpx
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.main import app
from app.database import Base, get_db

TEST_DATABASE_URL = "sqlite:///./test_appointments.db"
test_engine = create_engine(TEST_DATABASE_URL, connect_args={"check_same_thread": False})
TestSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=test_engine)


def override_get_db():
    db = TestSessionLocal()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db


@pytest.fixture(autouse=True)
def reset_db():
    Base.metadata.create_all(bind=test_engine)
    yield
    Base.metadata.drop_all(bind=test_engine)


client = TestClient(app)

VALID_PATIENT_RESPONSE = {
    "id": 1, "full_name": "Nimal Silva",
    "date_of_birth": "1985-03-15", "phone": "077123",
    "created_at": "2026-01-01T00:00:00",
}


def test_health():
    r = client.get("/health")
    assert r.status_code == 200


@respx.mock
def test_create_appointment_success(respx_mock):
    # Mock patient-service returning a valid patient
    respx_mock.get("http://patient-service-mock:8001/patients/1").mock(
        return_value=httpx.Response(200, json=VALID_PATIENT_RESPONSE)
    )
    # Mock audit-service (fire-and-forget)
    respx_mock.post("http://audit-mock:8003/audit").mock(
        return_value=httpx.Response(201, json={"event_id": "abc"})
    )
    # Mock notification-service (fire-and-forget)
    respx_mock.post("http://notify-mock:8004/notify").mock(
        return_value=httpx.Response(200, json={"sent": True})
    )

    r = client.post("/appointments", json={
        "patient_id": 1,
        "scheduled_for": "2026-07-15T10:00:00",
        "reason": "Annual checkup",
        "status": "scheduled",
    })
    assert r.status_code == 201
    body = r.json()
    assert body["patient_id"] == 1
    assert body["reason"] == "Annual checkup"
    assert "id" in body


@respx.mock
def test_create_appointment_patient_not_found(respx_mock):
    respx_mock.get("http://patient-service-mock:8001/patients/999").mock(
        return_value=httpx.Response(404, json={"detail": "Patient 999 not found"})
    )
    r = client.post("/appointments", json={
        "patient_id": 999,
        "scheduled_for": "2026-07-15T10:00:00",
        "reason": "Checkup",
    })
    assert r.status_code == 422
    assert "does not exist" in r.json()["detail"]


def test_list_appointments_empty():
    r = client.get("/appointments")
    assert r.status_code == 200
    assert r.json() == []


def test_get_appointment_not_found():
    r = client.get("/appointments/99999")
    assert r.status_code == 404
```

### `services/appointment-service/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

EXPOSE 8002

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
```

---

## 6. audit-service — Complete Code

**What it does:** receives audit events from other services and writes them to DynamoDB.
**Internal only** — never exposed via Ingress. Other services call it using the
Kubernetes cluster DNS name `http://audit-service:8003`.

### `services/audit-service/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.30.0
boto3==1.34.0
pydantic==2.7.1
prometheus-fastapi-instrumentator==6.1.0
pytest==8.2.0
pytest-asyncio==0.23.6
moto[dynamodb]==5.0.0
```

> `moto` is the standard library for mocking AWS services in Python tests.
> With `moto`, tests create a fake DynamoDB in memory — no real AWS account needed.

### `services/audit-service/app/__init__.py`

```python
# empty
```

### `services/audit-service/app/schemas.py`

```python
from pydantic import BaseModel, Field
from typing import Optional


class AuditEventIn(BaseModel):
    """Payload sent by other services when logging an event."""
    entity_type: str   = Field(..., description="e.g. 'patient', 'appointment'")
    entity_id:   str   = Field(..., description="ID of the entity that changed")
    action:      str   = Field(..., description="e.g. 'created', 'updated', 'deleted'")
    actor:       str   = Field(default="system", description="Which service fired this event")
    metadata:    Optional[dict] = Field(default=None, description="Extra context")


class AuditEventOut(BaseModel):
    """Response returned after successfully storing an audit event."""
    event_id: str
    ts:       str
```

### `services/audit-service/app/main.py`

```python
import os
import uuid
import logging
import boto3
from datetime import datetime, timezone
from fastapi import FastAPI, HTTPException
from .schemas import AuditEventIn, AuditEventOut

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("audit-service")

app = FastAPI(
    title="audit-service",
    description="Stores audit events in DynamoDB. Internal service only.",
    version="1.0.0",
)

DYNAMODB_TABLE    = os.environ.get("DYNAMODB_TABLE", "audit_events")
AWS_REGION        = os.environ.get("AWS_DEFAULT_REGION", "ap-south-1")
DYNAMODB_ENDPOINT = os.environ.get("DYNAMODB_ENDPOINT_URL")  # set for local dev

# Build the boto3 resource — endpoint_url is None in production (uses real AWS)
dynamodb = boto3.resource(
    "dynamodb",
    region_name=AWS_REGION,
    endpoint_url=DYNAMODB_ENDPOINT,
)


def get_table():
    return dynamodb.Table(DYNAMODB_TABLE)


@app.on_event("startup")
def startup():
    """
    Create the DynamoDB table if it doesn't exist.
    In production, the table is created by Terraform — this is only for local dev.
    """
    if DYNAMODB_ENDPOINT:  # only auto-create for local DynamoDB
        try:
            dynamodb.create_table(
                TableName=DYNAMODB_TABLE,
                KeySchema=[{"AttributeName": "event_id", "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": "event_id", "AttributeType": "S"}],
                BillingMode="PAY_PER_REQUEST",
            )
            logger.info("Created local DynamoDB table: %s", DYNAMODB_TABLE)
        except dynamodb.meta.client.exceptions.ResourceInUseException:
            pass  # table already exists — fine
    logger.info("audit-service started")


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health", tags=["health"])
def health():
    return {"status": "ok", "service": "audit-service"}


# ── Audit endpoint ────────────────────────────────────────────────────────────

@app.post("/audit", response_model=AuditEventOut, status_code=201, tags=["audit"])
def log_event(event: AuditEventIn):
    """
    Store an audit event. Called by patient-service and appointment-service
    via fire-and-forget background tasks.
    """
    event_id = str(uuid.uuid4())
    ts       = datetime.now(timezone.utc).isoformat()

    item = {
        "event_id":    event_id,
        "ts":          ts,
        "entity_type": event.entity_type,
        "entity_id":   event.entity_id,
        "action":      event.action,
        "actor":       event.actor,
    }
    if event.metadata:
        item["metadata"] = event.metadata

    try:
        get_table().put_item(Item=item)
    except Exception as exc:
        logger.error("DynamoDB put_item failed: %s", exc)
        raise HTTPException(status_code=500, detail="Failed to store audit event")

    logger.info("audit event stored: %s %s %s", event.entity_type, event.entity_id, event.action)
    return AuditEventOut(event_id=event_id, ts=ts)


@app.get("/audit", response_model=list[dict], tags=["audit"])
def list_events(limit: int = 50):
    """List recent audit events. For debugging only — not exposed via Ingress."""
    try:
        response = get_table().scan(Limit=limit)
        return response.get("Items", [])
    except Exception as exc:
        logger.error("DynamoDB scan failed: %s", exc)
        raise HTTPException(status_code=500, detail="Failed to fetch audit events")
```

### `services/audit-service/tests/__init__.py`

```python
# empty
```

### `services/audit-service/tests/test_audit.py`

```python
"""
Tests for audit-service.
Uses moto to create a fake DynamoDB in memory — no real AWS account needed.
"""
import os
os.environ.setdefault("DYNAMODB_TABLE",      "audit_events")
os.environ.setdefault("AWS_DEFAULT_REGION",  "ap-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID",    "test")   # moto requires these
os.environ.setdefault("AWS_SECRET_ACCESS_KEY","test")
os.environ.setdefault("DYNAMODB_ENDPOINT_URL","")       # empty = use real/mocked

import pytest
import boto3
from moto import mock_aws
from fastapi.testclient import TestClient


@pytest.fixture()
def aws_credentials():
    """Set fake AWS credentials so moto intercepts boto3 calls."""
    os.environ["AWS_ACCESS_KEY_ID"]     = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_DEFAULT_REGION"]    = "ap-south-1"


@pytest.fixture()
def dynamodb_table(aws_credentials):
    """Create a fake DynamoDB table using moto."""
    with mock_aws():
        client = boto3.resource("dynamodb", region_name="ap-south-1")
        table = client.create_table(
            TableName="audit_events",
            KeySchema=[{"AttributeName": "event_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "event_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        table.wait_until_exists()

        # Patch the module-level dynamodb resource to use moto
        import app.main as main_module
        main_module.dynamodb = client
        yield table


def get_client(dynamodb_table):
    from app.main import app
    return TestClient(app)


def test_health(dynamodb_table):
    client = get_client(dynamodb_table)
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_log_event(dynamodb_table):
    client = get_client(dynamodb_table)
    r = client.post("/audit", json={
        "entity_type": "patient",
        "entity_id":   "42",
        "action":      "created",
        "actor":       "patient-service",
    })
    assert r.status_code == 201
    body = r.json()
    assert "event_id" in body
    assert "ts" in body


def test_log_event_with_metadata(dynamodb_table):
    client = get_client(dynamodb_table)
    r = client.post("/audit", json={
        "entity_type": "appointment",
        "entity_id":   "7",
        "action":      "updated",
        "actor":       "appointment-service",
        "metadata":    {"patient_id": 42},
    })
    assert r.status_code == 201


def test_missing_required_fields(dynamodb_table):
    client = get_client(dynamodb_table)
    r = client.post("/audit", json={"entity_type": "patient"})
    assert r.status_code == 422
```

### `services/audit-service/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

EXPOSE 8003

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8003"]
```

---

## 7. notification-service — Complete Code

**What it does:** sends emails via AWS SES. Internal only — not exposed via Ingress.
In local development, emails are **logged to the console instead of actually sent**
so you don't need a real SES setup.

### `services/notification-service/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.30.0
boto3==1.34.0
pydantic[email]==2.7.1
prometheus-fastapi-instrumentator==6.1.0
pytest==8.2.0
pytest-asyncio==0.23.6
moto[ses]==5.0.0
```

### `services/notification-service/app/__init__.py`

```python
# empty
```

### `services/notification-service/app/schemas.py`

```python
from pydantic import BaseModel, EmailStr, Field


class NotificationRequest(BaseModel):
    """Payload sent by other services to trigger an email."""
    to:      EmailStr = Field(..., description="Recipient email address")
    subject: str      = Field(..., min_length=1, max_length=200, description="Email subject")
    body:    str      = Field(..., min_length=1, description="Plain text email body")


class NotificationResponse(BaseModel):
    sent: bool
    message: str
```

### `services/notification-service/app/main.py`

```python
import os
import logging
import boto3
from fastapi import FastAPI, HTTPException
from botocore.exceptions import ClientError
from .schemas import NotificationRequest, NotificationResponse

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("notification-service")

app = FastAPI(
    title="notification-service",
    description="Sends email notifications via SES. Internal service only.",
    version="1.0.0",
)

SES_FROM_ADDRESS = os.environ.get("SES_FROM_ADDRESS", "noreply@example.com")
AWS_REGION       = os.environ.get("AWS_DEFAULT_REGION", "ap-south-1")

# LOCAL_DEV=true means log the email instead of actually sending it
# This lets the service run locally without real AWS SES credentials
LOCAL_DEV = os.environ.get("LOCAL_DEV", "false").lower() == "true"

ses = boto3.client("ses", region_name=AWS_REGION)


@app.on_event("startup")
def startup():
    if LOCAL_DEV:
        logger.info("notification-service started in LOCAL_DEV mode — emails will be logged only")
    else:
        logger.info("notification-service started — emails will be sent via SES from %s",
                    SES_FROM_ADDRESS)


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health", tags=["health"])
def health():
    return {
        "status": "ok",
        "service": "notification-service",
        "mode": "local_dev" if LOCAL_DEV else "production",
    }


# ── Notify endpoint ───────────────────────────────────────────────────────────

@app.post("/notify", response_model=NotificationResponse, tags=["notifications"])
def send_notification(payload: NotificationRequest):
    """
    Send an email. In LOCAL_DEV mode, just logs — no real email is sent.
    """
    if LOCAL_DEV:
        # In local dev, print to console so you can see the "email" in docker compose logs
        logger.info(
            "📧 [LOCAL_DEV] Email would be sent:\n"
            "  To:      %s\n"
            "  Subject: %s\n"
            "  Body:    %s",
            payload.to, payload.subject, payload.body,
        )
        return NotificationResponse(sent=True, message="logged (LOCAL_DEV mode)")

    # Production: send via SES
    try:
        ses.send_email(
            Source=SES_FROM_ADDRESS,
            Destination={"ToAddresses": [payload.to]},
            Message={
                "Subject": {"Data": payload.subject, "Charset": "UTF-8"},
                "Body":    {"Text": {"Data": payload.body, "Charset": "UTF-8"}},
            },
        )
        logger.info("email sent to %s: %s", payload.to, payload.subject)
        return NotificationResponse(sent=True, message="sent via SES")

    except ClientError as exc:
        error_code = exc.response["Error"]["Code"]
        logger.error("SES send failed (%s): %s", error_code, exc)
        raise HTTPException(
            status_code=502,
            detail=f"Failed to send email: {error_code}",
        )
```

### `services/notification-service/tests/__init__.py`

```python
# empty
```

### `services/notification-service/tests/test_notification.py`

```python
"""
Tests for notification-service.
"""
import os
os.environ.setdefault("SES_FROM_ADDRESS",      "noreply@test.com")
os.environ.setdefault("AWS_DEFAULT_REGION",    "ap-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID",     "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("LOCAL_DEV",             "true")   # don't actually send emails

import pytest
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    data = r.json()
    assert data["status"] == "ok"
    assert data["mode"] == "local_dev"


def test_send_notification_local_dev():
    """In LOCAL_DEV mode, notification is logged and returns sent=True."""
    r = client.post("/notify", json={
        "to":      "patient@example.com",
        "subject": "Appointment Reminder",
        "body":    "Your appointment is tomorrow at 10:00.",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["sent"] is True
    assert "local_dev" in body["message"].lower()


def test_send_notification_invalid_email():
    r = client.post("/notify", json={
        "to":      "not-an-email",
        "subject": "Test",
        "body":    "Test body",
    })
    assert r.status_code == 422


def test_send_notification_empty_subject():
    r = client.post("/notify", json={
        "to":      "patient@example.com",
        "subject": "",
        "body":    "Test body",
    })
    assert r.status_code == 422
```

### `services/notification-service/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

EXPOSE 8004

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8004"]
```

---

## 8. The Docker Compose File

Now that all four services are written, create `services/docker-compose.yml`:

```yaml
version: "3.9"

# ── Shared network so services can find each other by name ────────────────────
networks:
  cloudcare:
    driver: bridge

services:

  # ── PostgreSQL ─────────────────────────────────────────────────────────────
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB:       cloudcare
      POSTGRES_USER:     admin
      POSTGRES_PASSWORD: local_password
    ports:
      - "5432:5432"    # expose to host for psql / pgAdmin access
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql   # run on first start
    networks:
      - cloudcare
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U admin -d cloudcare"]
      interval: 5s
      timeout: 3s
      retries: 10

  # ── DynamoDB Local ─────────────────────────────────────────────────────────
  dynamodb-local:
    image: amazon/dynamodb-local:2.3.0
    command: "-jar DynamoDBLocal.jar -sharedDb -inMemory"
    ports:
      - "8000:8000"
    networks:
      - cloudcare

  # ── patient-service ────────────────────────────────────────────────────────
  patient-service:
    build:
      context: ./patient-service
      dockerfile: Dockerfile
    ports:
      - "8001:8001"
    environment:
      DATABASE_URL:      "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
      DB_SCHEMA:         "patients"
      AUDIT_SERVICE_URL: "http://audit-service:8003"
      LOG_LEVEL:         "INFO"
    depends_on:
      postgres:
        condition: service_healthy   # wait until postgres is ready
    networks:
      - cloudcare

  # ── appointment-service ────────────────────────────────────────────────────
  appointment-service:
    build:
      context: ./appointment-service
      dockerfile: Dockerfile
    ports:
      - "8002:8002"
    environment:
      DATABASE_URL:             "postgresql://appt_svc:appt_pass@postgres:5432/cloudcare"
      DB_SCHEMA:                "appointments"
      PATIENT_SERVICE_URL:      "http://patient-service:8001"
      AUDIT_SERVICE_URL:        "http://audit-service:8003"
      NOTIFICATION_SERVICE_URL: "http://notification-service:8004"
      LOG_LEVEL:                "INFO"
    depends_on:
      postgres:
        condition: service_healthy
      patient-service:
        condition: service_started
    networks:
      - cloudcare

  # ── audit-service ──────────────────────────────────────────────────────────
  audit-service:
    build:
      context: ./audit-service
      dockerfile: Dockerfile
    ports:
      - "8003:8003"
    environment:
      DYNAMODB_TABLE:        "audit_events"
      AWS_DEFAULT_REGION:    "ap-south-1"
      DYNAMODB_ENDPOINT_URL: "http://dynamodb-local:8000"
      AWS_ACCESS_KEY_ID:     "local"        # dummy values for local DynamoDB
      AWS_SECRET_ACCESS_KEY: "local"
      LOG_LEVEL:             "INFO"
    depends_on:
      - dynamodb-local
    networks:
      - cloudcare

  # ── notification-service ───────────────────────────────────────────────────
  notification-service:
    build:
      context: ./notification-service
      dockerfile: Dockerfile
    ports:
      - "8004:8004"
    environment:
      SES_FROM_ADDRESS:   "noreply@cloudcare.local"
      AWS_DEFAULT_REGION: "ap-south-1"
      LOCAL_DEV:          "true"    # log emails to console, don't send via SES
      LOG_LEVEL:          "INFO"
    networks:
      - cloudcare

volumes:
  postgres_data:
    driver: local
```

---

## 9. Run All Services with Docker Compose

Now run everything for the first time:

```bash
cd services/
docker compose up --build
```

The `--build` flag forces Docker to build fresh images. The first run takes
2–5 minutes because it downloads the base Python image and installs packages.

You should see output like this:
```
postgres           | PostgreSQL init process complete; ready for start up.
patient-service    | INFO:     Started server process [1]
patient-service    | INFO:     Waiting for application startup.
patient-service    | INFO:patient-service:patient-service started, tables ready
patient-service    | INFO:     Application startup complete.
appointment-service | INFO:     Application startup complete.
audit-service      | INFO:audit-service:Created local DynamoDB table: audit_events
notification-service | INFO:notification-service:notification-service started in LOCAL_DEV mode
```

Once all four services show `Application startup complete`, open the Swagger UIs:

| Service | URL |
|---|---|
| patient-service | http://localhost:8001/docs |
| appointment-service | http://localhost:8002/docs |
| audit-service | http://localhost:8003/docs |
| notification-service | http://localhost:8004/docs |

---

## 10. Test End-to-End in the Correct Order

Open a **second terminal** (keep docker compose running in the first) and run:

### Step 1: Create a patient

```bash
curl -s -X POST http://localhost:8001/patients \
  -H "Content-Type: application/json" \
  -d '{
    "full_name": "Nimal Silva",
    "date_of_birth": "1985-03-15",
    "phone": "0771234567"
  }' | python3 -m json.tool
```

Expected response:
```json
{
  "full_name": "Nimal Silva",
  "date_of_birth": "1985-03-15",
  "phone": "0771234567",
  "id": 1,
  "created_at": "2026-06-10T09:00:00Z"
}
```

Note the `"id": 1` — we'll use this next.

### Step 2: Verify patient was created

```bash
curl -s http://localhost:8001/patients | python3 -m json.tool
# Should show [{"id": 1, "full_name": "Nimal Silva", ...}]
```

### Step 3: Create an appointment for that patient

```bash
curl -s -X POST http://localhost:8002/appointments \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id": 1,
    "scheduled_for": "2026-07-15T10:00:00",
    "reason": "Annual health checkup",
    "status": "scheduled"
  }' | python3 -m json.tool
```

Expected response:
```json
{
  "patient_id": 1,
  "scheduled_for": "2026-07-15T10:00:00",
  "reason": "Annual health checkup",
  "status": "scheduled",
  "id": 1,
  "created_at": "2026-06-10T09:01:00Z"
}
```

### Step 4: Try to create an appointment for a non-existent patient

```bash
curl -s -X POST http://localhost:8002/appointments \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id": 999,
    "scheduled_for": "2026-07-15T11:00:00",
    "reason": "Test"
  }' | python3 -m json.tool
```

Expected: `422 Unprocessable Entity` with `"Patient 999 does not exist"`.
This proves appointment-service is calling patient-service to verify the patient.

### Step 5: Check audit events were recorded

```bash
curl -s http://localhost:8003/audit | python3 -m json.tool
# Should show events for: patient created, appointment created
```

### Step 6: Check notification logs (in the docker compose terminal)

Look at the docker compose terminal output. You should see lines like:
```
notification-service | INFO:notification-service:📧 [LOCAL_DEV] Email would be sent:
notification-service |   To:      patient@example.com
notification-service |   Subject: Appointment Confirmed
notification-service |   Body:    Your appointment on 2026-07-15 10:00:00 has been confirmed.
```

All four services are working and talking to each other.

---

## 11. Run Tests for Each Service

Open a new terminal. Run tests for each service:

```bash
# patient-service
cd services/patient-service
pip install -r requirements.txt
pytest tests/ -v

# appointment-service
cd ../appointment-service
pip install -r requirements.txt
pytest tests/ -v

# audit-service
cd ../audit-service
pip install -r requirements.txt
pytest tests/ -v

# notification-service
cd ../notification-service
pip install -r requirements.txt
pytest tests/ -v
```

All tests should pass with output like:
```
PASSED tests/test_patients.py::test_health
PASSED tests/test_patients.py::test_create_patient
PASSED tests/test_patients.py::test_list_patients_empty
...
10 passed in 0.82s
```

---

## 12. Stop Everything

```bash
# In the docker compose terminal:
Ctrl+C

# Then clean up containers (keep data volumes):
docker compose down

# Or clean up everything including data:
docker compose down -v
```

---

## 13. Inter-Service Communication Summary

```
patient-service
  ← receives: POST /patients, GET /patients, GET /patients/{id}, PUT, DELETE
  → calls:    audit-service (POST /audit) — fire and forget

appointment-service
  ← receives: POST /appointments, GET /appointments, GET /appointments/{id}, PUT, DELETE
  → calls:    patient-service (GET /patients/{id}) — SYNCHRONOUS (fails if patient not found)
  → calls:    audit-service (POST /audit) — fire and forget
  → calls:    notification-service (POST /notify) — fire and forget

audit-service
  ← receives: POST /audit, GET /audit (debug)
  → calls:    DynamoDB (write only)

notification-service
  ← receives: POST /notify
  → calls:    AWS SES (in production) or logs to console (in LOCAL_DEV)
```

> 🧠 **Synchronous vs fire-and-forget:** The patient verification in
> appointment-service is *synchronous* — it waits for a response and returns an error
> if the patient doesn't exist. Audit and notification calls are *fire-and-forget*
> background tasks — if they fail, the main operation still succeeds. This is the
> right pattern: business-critical validation is synchronous; side effects are async.

---

## ✅ Checkpoint

You should be able to:

- [ ] Run `docker compose up --build` and see all 4 services start
- [ ] Create a patient via `curl` and get `id: 1` back
- [ ] Create an appointment for `patient_id: 1` — success
- [ ] Try `patient_id: 999` — get 422 error (proves inter-service call works)
- [ ] See audit events in `http://localhost:8003/audit`
- [ ] See notification logs in docker compose output
- [ ] Run `pytest tests/ -v` in each service directory — all green

**Next:** [03 — Kubernetes Manifests](03-k8s-manifests.md) — take these same services
and deploy them to minikube with proper Kubernetes YAML. Also complete the minikube
section in [01 — Local Setup](01-local-setup.md#6-running-the-services-on-minikube-do-this-after-doc-02).
