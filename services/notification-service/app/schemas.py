from pydantic import BaseModel, EmailStr, Field


class NotificationRequest(BaseModel):
    """Payload sent by other services to trigger an email."""
    to:      EmailStr = Field(..., description="Recipient email address")
    subject: str      = Field(..., min_length=1, max_length=200, description="Email subject")
    body:    str      = Field(..., min_length=1, description="Plain text email body")


class NotificationResponse(BaseModel):
    sent: bool
    message: str