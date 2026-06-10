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