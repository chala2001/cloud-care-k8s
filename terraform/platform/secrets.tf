# ── Random passwords for service-specific DB users ────────────────────────────
resource "random_password" "patient_db"      { length = 24; special = false }
resource "random_password" "appointment_db"  { length = 24; special = false }

# ── Secrets Manager secrets — one per service ─────────────────────────────────
# The External Secrets Operator (ESO) will sync these into Kubernetes Secrets (Doc 07)

resource "aws_secretsmanager_secret" "patient_db" {
  name = "cloudcare-k8s/patient-service/db"
  # path format: project/service/type — easy to manage with IAM path-based policies
}

resource "aws_secretsmanager_secret_version" "patient_db" {
  secret_id = aws_secretsmanager_secret.patient_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://patient_svc:${random_password.patient_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
    # patient_svc is the schema-specific postgres user (created by init.sql equivalent)
    # aws_db_instance.main.endpoint = the RDS hostname (set by AWS after creation)
  })
}

resource "aws_secretsmanager_secret" "appointment_db" {
  name = "cloudcare-k8s/appointment-service/db"
}

resource "aws_secretsmanager_secret_version" "appointment_db" {
  secret_id = aws_secretsmanager_secret.appointment_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://appt_svc:${random_password.appointment_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
  })
}