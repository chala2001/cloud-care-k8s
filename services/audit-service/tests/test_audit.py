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