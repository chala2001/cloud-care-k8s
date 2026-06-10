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