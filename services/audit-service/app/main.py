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