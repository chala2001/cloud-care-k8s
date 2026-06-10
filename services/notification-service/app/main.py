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