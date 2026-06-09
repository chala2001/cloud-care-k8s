# 02 — Microservices Split

> **Goal of this doc:** understand *why* the monolith from CloudCare v1 is split into
> four services, *where* each boundary is drawn, and *how* the FastAPI code for each
> service is structured. By the end you will know exactly what each service owns and
> why.

---

## 1. What Was the Monolith?

In CloudCare v1, the entire backend was one FastAPI application — one Python process,
one Docker image, one deployment. It handled patients, appointments, auditing, and email
notifications all in the same codebase.

```
v1 monolith (one app):
  /patients          ← reads/writes patients table
  /appointments      ← reads/writes appointments table
  /audit             ← writes to DynamoDB
  /notify            ← sends email via SES
```

**This works fine at small scale.** But it has real problems:

- To update the appointment logic, you redeploy the *entire* app — including patient
  and audit code that hasn't changed.
- If the notification feature has a bug that causes high memory usage, it affects
  patient queries too — they share the same process.
- You can't scale appointments independently from patients.
- The deployment pipeline is one pipeline for everything.

> 🧠 **Microservices solve exactly these problems.** Each service is an independent
> unit: its own codebase, its own Docker image, its own deployment, its own scaling
> rules. Changing notification code doesn't require touching patient code. If
> appointment-service needs 5 replicas under load, patient-service stays at 1.

---

## 2. How We Split the Monolith

The four services in CloudCare-K8s map directly to the four concerns of the old
monolith:

| Old route | New service | Port | Data it owns |
|---|---|---|---|
| `/patients` | **patient-service** | 8001 | `patients` PostgreSQL schema |
| `/appointments` | **appointment-service** | 8002 | `appointments` PostgreSQL schema |
| `/audit` | **audit-service** | 8003 | DynamoDB `audit_events` table |
| `/notify` | **notification-service** | 8004 | Nothing persistent — calls SES |

**The golden rule:** a service owns its data. No other service reads or writes its
database directly. Communication between services happens over HTTP (or a message bus
in more advanced systems) — never via shared database tables.

---

## 3. The Database-per-Service Pattern

In a true production microservices system, each service has its **own separate database
instance**. This gives:

- **Blast-radius isolation**: a DB outage in one service doesn't affect others.
- **Independent schema evolution**: patient-service can add columns without a
  coordinated multi-service migration.
- **Technology choice**: one service could use PostgreSQL, another MongoDB.

At free-tier scale, separate RDS instances would cost ~$50/month **each** — too much for
a learning project. Instead, we use **schema-level isolation on one RDS instance**:

```
RDS PostgreSQL instance (shared)
│
└── Database: cloudcare
    ├── Schema: patients         ← only patient_svc DB user can access this
    └── Schema: appointments     ← only appt_svc DB user can access this
```

Each service gets its own PostgreSQL **user** with permissions only on its own schema:

```sql
-- Run once during setup
CREATE SCHEMA patients;
CREATE SCHEMA appointments;

CREATE USER patient_svc WITH PASSWORD 'secret1';
GRANT USAGE, CREATE ON SCHEMA patients TO patient_svc;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA patients TO patient_svc;

CREATE USER appt_svc WITH PASSWORD 'secret2';
GRANT USAGE, CREATE ON SCHEMA appointments TO appt_svc;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA appointments TO appt_svc;
```

`patient_svc` cannot even see the `appointments` schema — the database enforces
the boundary. This is the correct ownership model. If we later moved to separate
instances, the process is: dump schema → restore to new RDS → update Secrets Manager
secret → redeploy the service.

---

## 4. patient-service

**What it does:** manages patient records. Simple CRUD.

**Code structure:**
```
services/patient-service/
├── app/
│   ├── main.py          ← FastAPI app, routes
│   ├── database.py      ← SQLAlchemy setup, schema=patients
│   ├── models.py        ← Patient SQLAlchemy model
│   └── schemas.py       ← Pydantic request/response schemas
├── tests/
│   └── test_patients.py ← pytest tests
├── Dockerfile
└── requirements.txt
```

`app/main.py`:
```python
from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from . import models, schemas, database

app = FastAPI(title="patient-service")

@app.get("/health")
def health():
    return {"status": "ok", "service": "patient-service"}

@app.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(patient: schemas.PatientIn, db: Session = Depends(database.get_db)):
    db_patient = models.Patient(**patient.dict())
    db.add(db_patient)
    db.commit()
    db.refresh(db_patient)
    return db_patient

@app.get("/patients", response_model=list[schemas.PatientOut])
def list_patients(db: Session = Depends(database.get_db)):
    return db.query(models.Patient).all()

@app.get("/patients/{patient_id}", response_model=schemas.PatientOut)
def get_patient(patient_id: int, db: Session = Depends(database.get_db)):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail="Patient not found")
    return patient

@app.put("/patients/{patient_id}", response_model=schemas.PatientOut)
def update_patient(patient_id: int, data: schemas.PatientIn, db: Session = Depends(database.get_db)):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail="Patient not found")
    for key, value in data.dict().items():
        setattr(patient, key, value)
    db.commit()
    db.refresh(patient)
    return patient

@app.delete("/patients/{patient_id}", status_code=204)
def delete_patient(patient_id: int, db: Session = Depends(database.get_db)):
    patient = db.query(models.Patient).filter(models.Patient.id == patient_id).first()
    if not patient:
        raise HTTPException(status_code=404, detail="Patient not found")
    db.delete(patient)
    db.commit()
```

`app/database.py`:
```python
import os
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = os.environ["DATABASE_URL"]
DB_SCHEMA = os.environ.get("DB_SCHEMA", "patients")

engine = create_engine(DATABASE_URL)

# Set search_path so all queries go to the patients schema
@event.listens_for(engine, "connect")
def set_search_path(dbapi_conn, connection_record):
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
```

`app/models.py`:
```python
from sqlalchemy import Column, Integer, String, Date, DateTime
from sqlalchemy.sql import func
from .database import Base

class Patient(Base):
    __tablename__ = "patients"

    id = Column(Integer, primary_key=True, index=True)
    full_name = Column(String, nullable=False)
    date_of_birth = Column(Date, nullable=False)
    phone = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
```

`Dockerfile`:
```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

EXPOSE 8001
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
```

`requirements.txt`:
```
fastapi==0.111.0
uvicorn[standard]==0.30.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
pydantic==2.7.1
```

---

## 5. appointment-service

**What it does:** manages appointments. Also calls patient-service to verify a patient
exists before creating an appointment.

**Why the inter-service call?** appointment-service needs to know a patient exists
before booking. But it cannot query the patients table directly (schema isolation).
Instead, it calls `GET /patients/{id}` on patient-service. This is the microservices
contract: communicate via APIs, not shared databases.

`app/main.py` (key difference — the patient check):
```python
import os
import httpx
from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from . import models, schemas, database

app = FastAPI(title="appointment-service")

PATIENT_SERVICE_URL = os.environ.get("PATIENT_SERVICE_URL", "http://patient-service:8001")

@app.post("/appointments", response_model=schemas.AppointmentOut, status_code=201)
async def create_appointment(appt: schemas.AppointmentIn, db: Session = Depends(database.get_db)):
    # Verify patient exists in patient-service
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{PATIENT_SERVICE_URL}/patients/{appt.patient_id}")
    if resp.status_code == 404:
        raise HTTPException(status_code=422, detail=f"Patient {appt.patient_id} not found")
    if resp.status_code != 200:
        raise HTTPException(status_code=503, detail="patient-service unavailable")

    db_appt = models.Appointment(**appt.dict())
    db.add(db_appt)
    db.commit()
    db.refresh(db_appt)
    return db_appt
```

> 🧠 **Service discovery in Kubernetes.** When appointment-service runs in the `dev`
> namespace and calls `http://patient-service:8001`, Kubernetes resolves that DNS name
> to the patient-service pod via the cluster's built-in DNS. The full DNS name is
> `patient-service.dev.svc.cluster.local:8001` — Kubernetes lets you use the short
> form (`patient-service`) when both services are in the same namespace.

---

## 6. audit-service

**What it does:** receives audit events from other services and writes them to DynamoDB.
It is **internal only** — not exposed via the Ingress controller. Only pods inside the
cluster can call it.

```python
import os
import boto3
from fastapi import FastAPI
from datetime import datetime, timezone
import uuid

app = FastAPI(title="audit-service")

DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-south-1"))
table = dynamodb.Table(DYNAMODB_TABLE)

@app.post("/audit", status_code=201)
async def log_event(event: dict):
    item = {
        "event_id": str(uuid.uuid4()),
        "ts": datetime.now(timezone.utc).isoformat(),
        "entity_type": event.get("entity_type"),
        "entity_id": str(event.get("entity_id")),
        "action": event.get("action"),
        "actor": event.get("actor", "system"),
    }
    table.put_item(Item=item)
    return {"event_id": item["event_id"]}
```

In production, other services call audit-service after any state change:
```python
# In patient-service, after creating a patient:
async with httpx.AsyncClient() as client:
    await client.post("http://audit-service:8003/audit", json={
        "entity_type": "patient",
        "entity_id": new_patient.id,
        "action": "created",
    })
```

---

## 7. notification-service

**What it does:** sends email notifications via AWS SES. Internal only — not exposed
via Ingress.

```python
import os
import boto3
from fastapi import FastAPI

app = FastAPI(title="notification-service")

SES_FROM_ADDRESS = os.environ["SES_FROM_ADDRESS"]
ses = boto3.client("ses", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-south-1"))

@app.post("/notify", status_code=200)
async def send_notification(payload: dict):
    ses.send_email(
        Source=SES_FROM_ADDRESS,
        Destination={"ToAddresses": [payload["to"]]},
        Message={
            "Subject": {"Data": payload["subject"]},
            "Body": {"Text": {"Data": payload["body"]}},
        },
    )
    return {"sent": True}
```

> 🧠 **Why not Lambda for email?** In CloudCare v1, email was sent by a Lambda function
> invoked via API Gateway. In v2, we replace it with a Kubernetes pod. Both approaches
> work — the v2 approach keeps all infrastructure inside the cluster, which simplifies
> networking and security group rules. The trade-off: Lambda scales to zero (cost) while
> a pod always runs.

---

## 8. The Services Directory Structure

```
services/
├── docker-compose.yml              ← all 4 services + postgres + dynamodb-local
├── init.sql                        ← creates schemas and DB users on first run
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
│   └── ... (same structure)
├── audit-service/
│   └── ... (same structure)
└── notification-service/
    └── ... (same structure)
```

---

## 9. Inter-Service Communication Summary

```
patient-service    ← no outbound calls (it's the source of truth for patients)
appointment-service → calls patient-service (GET /patients/{id}) before creating
appointment-service → calls audit-service (POST /audit) after creating
patient-service    → calls audit-service (POST /audit) after mutations
notification-service ← called by appointment-service (POST /notify) for new bookings
```

In Kubernetes, all these calls use short DNS names (`http://patient-service:8001`)
that resolve within the cluster. Nothing crosses the public internet.

---

## ✅ Checkpoint

You should be able to answer:

- Why do we split the monolith into four services?
- What does "schema-per-service isolation" mean and why is it the right pattern?
- Why does appointment-service call patient-service via HTTP instead of querying its table?
- How does Kubernetes service discovery work (short DNS names)?
- What is the difference between an externally-accessible service and an internal one?

Next: **[03 — Kubernetes Manifests](03-k8s-manifests.md)** — write the Deployment,
Service, and Ingress YAML that tells Kubernetes how to run these services.
