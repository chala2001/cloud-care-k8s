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