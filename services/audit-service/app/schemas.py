from pydantic import BaseModel, Field
from typing import Optional


class AuditEventIn(BaseModel):
    """Payload sent by other services when logging an event."""
    entity_type: str   = Field(..., description="e.g. 'patient', 'appointment'")
    entity_id:   str   = Field(..., description="ID of the entity that changed")
    action:      str   = Field(..., description="e.g. 'created', 'updated', 'deleted'")
    actor:       str   = Field(default="system", description="Which service fired this event")
    metadata:    Optional[dict] = Field(default=None, description="Extra context")


class AuditEventOut(BaseModel):
    """Response returned after successfully storing an audit event."""
    event_id: str
    ts:       str