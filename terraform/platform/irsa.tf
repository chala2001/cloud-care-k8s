# ── DynamoDB table for audit events ──────────────────────────────────────────
# audit-service writes every patient/appointment mutation here (fire-and-forget)
resource "aws_dynamodb_table" "audit_events" {
  name         = "audit_events"      # matches DYNAMODB_TABLE env var in audit-service
  billing_mode = "PAY_PER_REQUEST"   # no capacity planning — pay per read/write
  hash_key     = "event_id"          # partition key — each event has a UUID

  attribute {
    name = "event_id"
    type = "S"    # S = String (UUID stored as string)
  }
}

# ── IRSA role: audit-service → DynamoDB ──────────────────────────────────────
# IRSA (IAM Roles for Service Accounts): pod-level AWS identity without stored keys
# The EKS OIDC provider exchanges a Kubernetes ServiceAccount JWT for temporary AWS creds
resource "aws_iam_role" "audit_service" {
  name = "cloudcare-k8s-audit-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.terraform_remote_state.eks.outputs.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # only the audit-service ServiceAccount in the prod namespace can assume this role
          # format: <oidc-url>:sub = system:serviceaccount:<namespace>:<serviceaccount-name>
          "${data.terraform_remote_state.eks.outputs.oidc_provider_url}:sub" = "system:serviceaccount:prod:audit-service"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "audit_service" {
  name = "cloudcare-k8s-audit-service"
  role = aws_iam_role.audit_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",     # write new audit events
        "dynamodb:GetItem",     # read single event by ID
        "dynamodb:Scan",        # list events (used by GET /audit)
        "dynamodb:Query",       # query by index (future use)
        "dynamodb:UpdateItem",  # update event (not currently used, but good practice)
        "dynamodb:DeleteItem"   # delete event (not currently used)
      ]
      Resource = aws_dynamodb_table.audit_events.arn    # scoped to THIS table only
    }]
  })
}

# ── IRSA role: notification-service → SES ────────────────────────────────────
# notification-service calls SES to send transactional email (appointment confirmations etc.)
resource "aws_iam_role" "notification_service" {
  name = "cloudcare-k8s-notification-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.terraform_remote_state.eks.outputs.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # only notification-service in prod namespace can assume this role
          "${data.terraform_remote_state.eks.outputs.oidc_provider_url}:sub" = "system:serviceaccount:prod:notification-service"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "notification_service" {
  name = "cloudcare-k8s-notification-service"
  role = aws_iam_role.notification_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "ses:SendEmail",       # send plain HTML/text emails
        "ses:SendRawEmail"     # send emails with attachments (not used yet, future-proof)
      ]
      Resource = "*"    # SES doesn't support resource-level permissions on send actions
      # NOTE: SES requires email address verification before you can send in sandbox mode
      # verify sender via: aws ses verify-email-identity --email-address noreply@yourдomain.com
    }]
  })
}

output "audit_service_role_arn" {
  value = aws_iam_role.audit_service.arn
  # used in helm/audit-service/values-prod.yaml → serviceAccount.roleArn
}

output "notification_service_role_arn" {
  value = aws_iam_role.notification_service.arn
  # used in helm/notification-service/values-prod.yaml → serviceAccount.roleArn
}
