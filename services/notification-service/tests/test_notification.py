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