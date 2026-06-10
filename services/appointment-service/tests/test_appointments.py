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