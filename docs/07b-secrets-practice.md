# 07b — Secrets Practice: Every File, Every Line

> **Read 07a first.** This doc covers: IRSA roles in Terraform (irsa.tf), manual K8s
> Secrets from Secrets Manager, the Helm `databaseSecretName` pattern, the DB user
> initialization procedure, and how IRSA gives audit/notification pods AWS credentials.

---

## Issues encountered during this phase (and how we solved them)

| Issue | Error | Fix |
|-------|-------|-----|
| **Secrets deletion queue** | `InvalidRequestException: You can't create this secret because a secret with this name is already scheduled for deletion` | Added `recovery_window_in_days = 0` to secrets.tf. One-time fix for existing queue: `aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery` |
| **DATABASE_URL KeyError / empty env** | `KeyError: 'DATABASE_URL'` at pod startup | Using `--set` with Helm mangles URLs containing `://` and `@`. Fixed by creating a K8s Secret and reading it via `secretKeyRef` instead of passing the URL as a Helm value |
| **DB users not in PostgreSQL** | `password authentication failed for user "patient_svc"` | Terraform creates Secrets Manager entries but never runs `CREATE USER` in PostgreSQL. Fixed by running a one-time psql pod inside the cluster (see Section 2 below) |
| **Node capacity full** | `Too many pods — cannot schedule` | t3.small holds ~10 pods. Scale failing services to 0 replicas before adding init pods; scale back after |
| **Audit events empty after POST** | `GET /audit` returns `[]` even after creating a patient | audit-service posts events as a background task (fires after the response). Wait 2 seconds before checking. Not a bug — fire-and-forget by design |

---

## 1. Terraform: IRSA roles and DynamoDB table (`terraform/platform/irsa.tf`)

This file creates:
- The DynamoDB table for audit events
- An IRSA role for audit-service (DynamoDB access)
- An IRSA role for notification-service (SES access)
- Outputs so Helm charts can reference the role ARNs

```hcl
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
        "dynamodb:UpdateItem",  # update event (not currently used)
        "dynamodb:DeleteItem"   # delete event (not currently used)
      ]
      Resource = aws_dynamodb_table.audit_events.arn    # scoped to THIS table only
    }]
  })
}

# ── IRSA role: notification-service → SES ────────────────────────────────────
# notification-service calls SES to send transactional email
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
        "ses:SendRawEmail"     # send emails with attachments (future-proof)
      ]
      Resource = "*"    # SES doesn't support resource-level permissions on send actions
      # NOTE: SES requires email address verification before you can send in sandbox mode
      # verify sender via: aws ses verify-email-identity --email-address noreply@yourdomain.com
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
```

**Apply it:**
```bash
# From the platform stack directory
cd terraform/platform

# Creates the DynamoDB table and two IRSA roles
terraform apply

# Confirm the role ARNs are in the output
terraform output audit_service_role_arn
terraform output notification_service_role_arn
```

---

## 2. Initialize the database (one-time after RDS creation)

Terraform creates the RDS instance and stores credentials in Secrets Manager,
but it **never runs `CREATE USER` in PostgreSQL**. The service-specific users
(`patient_svc`, `appt_svc`) must be created manually. RDS is not publicly accessible,
so this is done via a temporary psql pod inside the cluster.

### Why this is needed

Secrets Manager stores a `DATABASE_URL` like:
```
postgresql://patient_svc:PASSWORD@RDS_HOST:5432/cloudcare
```

But that user doesn't exist in PostgreSQL until you create it. Services will
`CrashLoopBackOff` with `password authentication failed for user "patient_svc"` until this runs.

### The init procedure

```bash
# Get the master password from Terraform state (set by random_password.db_master)
MASTER_PASS=$(cd terraform/platform && terraform output -raw db_master_password 2>/dev/null || \
  aws secretsmanager get-secret-value \
    --secret-id cloudcare-k8s/master/db --query SecretString --output text \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# Get service passwords from Secrets Manager
PATIENT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/patient-service/db --query SecretString --output text \
  | python3 -c "import sys,json; from urllib.parse import urlparse; print(urlparse(json.load(sys.stdin)['DATABASE_URL']).password)")

APPT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/appointment-service/db --query SecretString --output text \
  | python3 -c "import sys,json; from urllib.parse import urlparse; print(urlparse(json.load(sys.stdin)['DATABASE_URL']).password)")

# Get the RDS hostname (without port)
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier cloudcare-k8s-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# If nodes are tight on capacity (t3.small fits ~10 pods), scale down app pods first
# to make room for the init pod
kubectl scale deployment patient-service appointment-service -n prod --replicas=0 2>/dev/null; true

# Run a one-shot postgres pod inside the cluster — it can reach the private RDS endpoint
kubectl run psql-init -n prod --restart=Never --image=postgres:16 -- sleep 300

# Wait for the pod to be ready
kubectl wait pod/psql-init -n prod --for=condition=Ready --timeout=60s

# Create service users and grant schema permissions
# sslmode=require is mandatory for RDS
kubectl exec -n prod psql-init -- psql \
  "postgresql://cloudcare_admin:${MASTER_PASS}@${RDS_HOST}/cloudcare?sslmode=require" \
  -c "CREATE USER patient_svc WITH PASSWORD '${PATIENT_PASS}';" \
  -c "CREATE SCHEMA IF NOT EXISTS patients;" \
  -c "GRANT CONNECT ON DATABASE cloudcare TO patient_svc;" \
  -c "GRANT USAGE, CREATE ON SCHEMA patients TO patient_svc;" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA patients GRANT ALL ON TABLES TO patient_svc;" \
  -c "CREATE USER appt_svc WITH PASSWORD '${APPT_PASS}';" \
  -c "CREATE SCHEMA IF NOT EXISTS appointments;" \
  -c "GRANT CONNECT ON DATABASE cloudcare TO appt_svc;" \
  -c "GRANT USAGE, CREATE ON SCHEMA appointments TO appt_svc;" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA appointments GRANT ALL ON TABLES TO appt_svc;"

# Clean up the init pod
kubectl delete pod psql-init -n prod

# Scale app services back up
kubectl scale deployment patient-service appointment-service -n prod --replicas=2
```

> **Repeat this whenever RDS is recreated.** `terraform destroy` + `terraform apply`
> creates a new RDS instance with no users. The procedure above must run again.

---

## 3. Create K8s Secrets from Secrets Manager

Services read `DATABASE_URL` from a Kubernetes Secret. We don't pass it via
`--set` in Helm because Helm mangles URLs containing `://` and `@`.

```bash
# Pull the full DATABASE_URL for each service from Secrets Manager
PATIENT_DB_URL=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/patient-service/db --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_URL'])")

APPT_DB_URL=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/appointment-service/db --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_URL'])")

# Create the prod namespace if it doesn't exist
kubectl create namespace prod 2>/dev/null || true

# Create K8s Secrets in the prod namespace
# --dry-run=client -o yaml | kubectl apply -f - is idempotent (safe to re-run)
kubectl create secret generic patient-service-db-secret \
  --from-literal=DATABASE_URL="$PATIENT_DB_URL" \
  -n prod --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic appointment-service-db-secret \
  --from-literal=DATABASE_URL="$APPT_DB_URL" \
  -n prod --dry-run=client -o yaml | kubectl apply -f -

# Verify the secrets exist (values are base64-encoded — this is normal, not plain text)
kubectl get secret patient-service-db-secret -n prod
kubectl get secret appointment-service-db-secret -n prod
```

> **Why `--dry-run=client -o yaml | kubectl apply` instead of `kubectl create`?**
> `kubectl create secret` fails with "already exists" if you run it twice.
> The dry-run pattern generates a manifest and applies it — idempotent like Terraform.
> These secrets survive `helm upgrade` because Helm didn't create them.

---

## 4. Helm chart: ServiceAccount template for IRSA

IRSA works because of an annotation on the Kubernetes ServiceAccount. The EKS webhook
reads the annotation, injects `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` env vars
into the pod, and boto3/AWS SDK picks them up automatically.

Create `helm/audit-service/templates/serviceaccount.yaml`:

```yaml
{{- if .Values.serviceAccount.roleArn }}
# Only create this ServiceAccount when a role ARN is provided (i.e. in prod)
# In dev, the pod uses the default ServiceAccount (no AWS credentials injected)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Release.Name }}          # "audit-service" — must match the Deployment below
  namespace: {{ .Release.Namespace }}
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.serviceAccount.roleArn }}
    # this annotation is the IRSA trigger
    # the EKS pod identity webhook reads it and injects:
    #   AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
    #   AWS_ROLE_ARN=arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service
    # boto3 calls sts:AssumeRoleWithWebIdentity automatically using those env vars
{{- end }}
```

Do the same for `helm/notification-service/templates/serviceaccount.yaml`.

---

## 5. Helm chart: Deployment references the ServiceAccount

In `helm/audit-service/templates/deployment.yaml`, add `serviceAccountName` to the pod spec:

```yaml
spec:
  template:
    spec:
      {{- if .Values.serviceAccount.roleArn }}
      serviceAccountName: {{ .Release.Name }}
      # runs this pod AS the ServiceAccount with the IRSA annotation
      # without this line, the pod uses the "default" ServiceAccount
      # which has no IRSA annotation → no AWS credentials injected
      {{- end }}
      containers:
        - name: audit-service
          ...
```

Do the same for `helm/notification-service/templates/deployment.yaml`.

---

## 6. Helm values: serviceAccount.roleArn

In `helm/audit-service/values.yaml` (the base defaults):
```yaml
serviceAccount:
  roleArn: ""    # empty by default — dev uses local DynamoDB, no IRSA needed
```

In `helm/audit-service/values-prod.yaml` (prod overrides):
```yaml
serviceAccount:
  roleArn: "arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service"
  # paste the ARN from terraform output audit_service_role_arn
```

In `helm/notification-service/values-prod.yaml`:
```yaml
serviceAccount:
  roleArn: "arn:aws:iam::670794226080:role/cloudcare-k8s-notification-service"
  # paste the ARN from terraform output notification_service_role_arn
```

---

## 7. Helm chart: `databaseSecretName` pattern for DB credentials

For patient-service and appointment-service, `DATABASE_URL` comes from a K8s Secret
(not from a Helm value). We use a `databaseSecretName` Helm value to point at it.

This pattern has three-way priority in `deployment.yaml`:
1. If `databaseSecretName` is set → read `DATABASE_URL` from that K8s Secret
2. Else if `externalSecret.enabled=true` → read from the ESO-managed secret (future)
3. Else → use the `databaseUrl` string value (dev / local)

`helm/patient-service/templates/deployment.yaml` — the DATABASE_URL section:

```yaml
env:
  {{- range $key, $val := .Values.env }}
  - name: {{ $key }}
    value: {{ $val | quote }}
  {{- end }}

  {{- if .Values.databaseSecretName }}
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: {{ .Values.databaseSecretName }}    # e.g. "patient-service-db-secret"
        key: DATABASE_URL                          # the key inside that K8s Secret
  # this is the prod path: the K8s Secret was created from Secrets Manager credentials
  {{- else if not .Values.externalSecret.enabled }}
  - name: DATABASE_URL
    value: {{ .Values.databaseUrl | quote }}
  # this is the dev path: plain connection string from values-dev.yaml
  {{- else }}
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: patient-service-db-secret
        key: DATABASE_URL
  # this is the ESO path (future): ExternalSecret creates the K8s Secret automatically
  {{- end }}
```

`helm/patient-service/values.yaml` — add the new field:
```yaml
databaseSecretName: ""    # empty by default — set in values-prod.yaml to use a K8s Secret
```

`helm/patient-service/values-prod.yaml`:
```yaml
databaseSecretName: "patient-service-db-secret"
# the K8s Secret created in Section 3 above
# this takes priority over databaseUrl and externalSecret.enabled
```

Do the same for appointment-service (`"appointment-service-db-secret"`).

---

## 8. Apply order (when EKS is running)

```bash
# Step 1: Apply platform Terraform (creates DynamoDB table and IRSA roles)
cd terraform/platform && terraform apply

# Step 2: Initialize the database (one-time — see Section 2)
# Run the psql-init pod procedure to CREATE USER patient_svc and appt_svc in PostgreSQL

# Step 3: Create K8s Secrets from Secrets Manager values (see Section 3)
kubectl create secret generic patient-service-db-secret ...
kubectl create secret generic appointment-service-db-secret ...

# Step 4: Deploy all services with prod values (includes IRSA ServiceAccounts)
SHA=$(git rev-parse --short HEAD)
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.tag="$SHA" \
    --namespace prod --create-namespace
done

# Step 5: Verify IRSA is working for audit-service
# Check that AWS_WEB_IDENTITY_TOKEN_FILE is injected into the audit-service pod
kubectl exec -n prod deployment/audit-service -- env | grep AWS_ROLE_ARN
# Should print: AWS_ROLE_ARN=arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service

# Step 6: Verify the audit trail works end to end
ALB=$(kubectl get ingress cloudcare-ingress -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Create a patient — audit-service fires a background event after this
curl -X POST "http://$ALB/patients" \
  -H "Content-Type: application/json" \
  -d '{"full_name":"Jane Doe","date_of_birth":"1990-01-01","phone":"+94771234567"}'

# Wait 2 seconds — audit POST is a background task, fires after the HTTP response
sleep 2

# Check audit log — should show the patient creation event from DynamoDB
curl "http://$ALB/audit"
```

---

## 9. SES email verification (notification-service)

Before notification-service can send real emails, the sender address must be verified in SES.
AWS SES sandbox mode prevents sending to unverified addresses.

```bash
# Verify the sender address (you'll receive a confirmation email)
aws ses verify-email-identity \
  --email-address noreply@cloudcare.com \
  --region ap-south-1

# Check verification status
aws ses get-identity-verification-attributes \
  --identities noreply@cloudcare.com \
  --region ap-south-1
# Wait for VerificationStatus: "Success"

# Test a notification (replace with your own verified email in sandbox mode)
ALB=$(kubectl get ingress cloudcare-ingress -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -X POST "http://$ALB/notify" \
  -H "Content-Type: application/json" \
  -d '{"to":"yourverifiedemail@example.com","subject":"Test","body":"Hello from CloudCare"}'
```

> **Sandbox limitation:** In SES sandbox mode, both sender AND recipient must be verified.
> Request production access (SES console → "Request Production Access") to send to any address.

---

## ✅ Checkpoint — done when:

- [ ] `terraform/platform/irsa.tf` has DynamoDB table + roles for audit-service and notification-service
- [ ] DB users `patient_svc` and `appt_svc` exist in PostgreSQL (psql init ran successfully)
- [ ] `kubectl get secret patient-service-db-secret -n prod` shows the secret
- [ ] `kubectl get secret appointment-service-db-secret -n prod` shows the secret
- [ ] `kubectl exec -n prod deployment/audit-service -- env | grep AWS_ROLE_ARN` shows the ARN
- [ ] `kubectl exec -n prod deployment/patient-service -- env | grep DATABASE_URL` is empty (reads from Secret, not env)
- [ ] `POST /patients` + `GET /audit` shows an audit event in DynamoDB
- [ ] You can explain: why does `databaseSecretName` take priority over `databaseUrl`?
- [ ] You can explain: why do we NOT pass DATABASE_URL via `--set` in Helm?
- [ ] You can explain: what does the EKS pod identity webhook do when it sees the IRSA annotation?
- [ ] You can explain: why must the DB users be created manually after every RDS recreation?

Next: **[08a — HPA Concepts](08a-hpa-concepts.md)** — understand how Kubernetes
automatically scales pods up and down based on CPU load.
