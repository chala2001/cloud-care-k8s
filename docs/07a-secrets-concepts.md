# 07a — Secrets: IRSA and External Secrets Operator Concepts

> **Goal:** understand how pods get AWS credentials securely (IRSA) and how
> database passwords get into pods without being hardcoded (ESO).
> Read this fully before going to 07b.

---

## 1. The problem — pods need secrets

Your 4 microservices need secrets to run:

```
patient-service      → DATABASE_URL (postgres password)
appointment-service  → DATABASE_URL (postgres password)
audit-service        → AWS credentials (to write to DynamoDB)
notification-service → AWS credentials (to send via SES)
```

Where do these secrets come from? Three options, from worst to best:

---

## 2. Option 1 (bad) — hardcode in values.yaml

```yaml
# values-prod.yaml
databaseUrl: "postgresql://patient_svc:mypassword123@rds.host/cloudcare"
```

Problems:
- Password is in your git repository — anyone with repo access sees it
- If a developer's laptop is stolen, the password is exposed
- Rotating the password = edit git file + redeploy

---

## 3. Option 2 (okay) — Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: patient-db-secret
data:
  DATABASE_URL: cG9zdGdyZXNxbDovL...    # base64 encoded
```

Slightly better — not in git. But:
- base64 is **not encryption** — anyone who can run `kubectl get secret` reads it in plain text
- Secrets are stored unencrypted in etcd by default
- You still manually create the secret (copy-paste the password) → human error

---

## 4. Option 3 (our way) — AWS Secrets Manager + IRSA + ESO

```
AWS Secrets Manager   ← passwords live here, encrypted, access-controlled
       ↑
External Secrets Operator (ESO)   ← pod that reads from Secrets Manager
       ↓ creates
Kubernetes Secret   ← automatically populated, refreshed every hour
       ↓ reads
Your microservice pod
```

Nobody types the password anywhere. No passwords in git. Auto-rotates.

---

## 5. IRSA — deep dive

IRSA (IAM Roles for Service Accounts) is how a **pod proves its identity** to AWS.

We introduced it in 05a. Now we go deep.

### The core idea

Every pod runs as a Kubernetes ServiceAccount. Think of a ServiceAccount like
a badge — it identifies who the pod is.

```
pod "patient-service" runs as ServiceAccount "patient-service"
pod "audit-service"   runs as ServiceAccount "audit-service"
```

IRSA links a ServiceAccount to an IAM Role:

```
ServiceAccount "audit-service" in namespace "prod"
  ↕ linked via annotation
IAM Role "cloudcare-k8s-audit-service"
  ↕ grants
DynamoDB: PutItem on cloudcare-events table
```

The audit-service pod can write to DynamoDB. The patient-service pod cannot.
Least privilege — each pod only has the permissions it needs.

### The 6-step flow

```
1. EKS creates the OIDC provider
   (oidc.tf — already done)
   URL: https://oidc.eks.ap-south-1.amazonaws.com/id/ABC123

2. You create an IAM Role with a trust policy:
   "Trust tokens from OIDC issuer ABC123,
    IF ServiceAccount = audit-service in namespace prod"

3. You annotate the Kubernetes ServiceAccount:
   eks.amazonaws.com/role-arn: arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service

4. When the audit-service pod starts:
   The EKS Pod Identity webhook (runs automatically) injects two things:
   - AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
   - AWS_ROLE_ARN=arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service

5. The AWS SDK (boto3 in Python) automatically reads these env vars.
   It calls AWS STS: "Exchange this token for credentials for this role"

6. STS returns temporary credentials (valid 15 minutes, auto-refreshed).
   boto3 uses them — your code needs zero credential handling.
```

Your Python code just calls `boto3.client('dynamodb')` with no credentials.
The SDK finds them automatically via the injected env vars. Same code works
locally (uses your ~/.aws/credentials) and in prod (uses IRSA).

### What the IAM trust policy looks like

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::670794226080:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/ABC123"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.../id/ABC123:sub": "system:serviceaccount:prod:audit-service",
      "oidc.eks.../id/ABC123:aud": "sts.amazonaws.com"
    }
  }
}
```

`system:serviceaccount:prod:audit-service` = the audit-service ServiceAccount
in the prod namespace. Only this exact pod identity can assume this role.

---

## 6. External Secrets Operator (ESO)

IRSA solves AWS credentials for pods. But your patient-service needs a
**database password** — that's in Secrets Manager, not an IAM permission.

ESO is a Kubernetes controller (a pod that runs permanently in kube-system).
Its job: **watch ExternalSecret resources and sync them into Kubernetes Secrets.**

```
ExternalSecret (your YAML):
  "read cloudcare-k8s/patient-service/db from Secrets Manager
   and create a Kubernetes Secret called patient-db-secret"

ESO pod:
  - uses its own IRSA role (with Secrets Manager read permission)
  - reads the secret from Secrets Manager every 1 hour
  - creates/updates the Kubernetes Secret automatically
  - if the password is rotated in Secrets Manager → K8s Secret updates → pod reloads

patient-service pod:
  - reads DATABASE_URL from the Kubernetes Secret
  - never touches Secrets Manager directly
  - never has Secrets Manager IAM permissions
```

### The two ESO resources you write

**ClusterSecretStore** — tells ESO where to find secrets (Secrets Manager, region):
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: eso-service-account    # ESO's own ServiceAccount (has IRSA)
```

**ExternalSecret** — tells ESO which secret to sync for THIS service:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: patient-db-secret
spec:
  refreshInterval: 1h              # re-read from Secrets Manager every hour
  secretStoreRef:
    name: aws-secrets-manager      # use the ClusterSecretStore above
    kind: ClusterSecretStore
  target:
    name: patient-db-secret        # name of the K8s Secret to create
  data:
    - secretKey: DATABASE_URL      # key inside the K8s Secret
      remoteRef:
        key: cloudcare-k8s/patient-service/db     # path in Secrets Manager
        property: DATABASE_URL                    # field inside the JSON secret
```

One ExternalSecret per service. ESO handles the rest.

---

## 7. Which service needs which secrets

```
Service              IRSA role permissions          ESO syncs
─────────────────── ──────────────────────────────  ──────────────────────────
patient-service      none (ESO handles DB)           DATABASE_URL from SM
appointment-service  none (ESO handles DB)           DATABASE_URL from SM
audit-service        dynamodb:PutItem on events tbl  (no DB secret needed)
notification-service ses:SendEmail                   (no DB secret needed)
eso (the operator)   secretsmanager:GetSecretValue   (reads on behalf of all)
```

audit-service and notification-service use IRSA directly (boto3 auto-picks up creds).
patient-service and appointment-service get their DB password via ESO → K8s Secret.

---

## 8. The full picture

```
Secrets Manager:
  cloudcare-k8s/patient-service/db     = { DATABASE_URL: "postgresql://..." }
  cloudcare-k8s/appointment-service/db = { DATABASE_URL: "postgresql://..." }
         ↑ read by ESO (via IRSA)
         ↓ written as K8s Secrets
K8s Secret: patient-db-secret         → mounted into patient-service pod
K8s Secret: appointment-db-secret     → mounted into appointment-service pod

IAM Role: cloudcare-k8s-audit-service (via IRSA)
  → audit-service pod gets temp AWS creds → calls DynamoDB directly

IAM Role: cloudcare-k8s-notification-service (via IRSA)
  → notification-service pod gets temp AWS creds → calls SES directly
```

No passwords in git. No long-lived credentials anywhere. Auto-rotating.

---

**You understand IRSA and ESO. Go to [07b — Secrets Practice](07b-secrets-practice.md)
to write every Terraform and YAML file that makes this work.**
