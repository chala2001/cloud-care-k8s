# 07 — IRSA and External Secrets Operator

> **Goal of this doc:** understand how pods get AWS credentials (IRSA), how secrets
> flow from AWS Secrets Manager into pod environment variables (External Secrets
> Operator), and why this is far more secure than any alternative.

---

## 1. The Problem: How Does a Pod Get AWS Credentials?

Your pods need AWS credentials to call AWS APIs:
- `patient-service` needs to read its DB credentials from Secrets Manager
- `audit-service` needs to write to DynamoDB
- `notification-service` needs to call SES

**Bad approach 1 — hardcode credentials in environment variables:**
```yaml
env:
  - name: AWS_ACCESS_KEY_ID
    value: "AKIAIOSFODNN7EXAMPLE"   # ← committed to Git = instant security incident
```

**Bad approach 2 — give the EC2 node an IAM instance profile:**
The node gets credentials. All pods on that node share the same credentials.
A compromised pod can call ANY AWS API the node can — it's not least-privilege.

**The right approach — IRSA (IAM Roles for Service Accounts):**
Each pod gets its own IAM role with only the permissions it needs. If `audit-service`
is compromised, the attacker can only write to the audit DynamoDB table —
not read DB passwords, not send emails, not touch anything else.

---

## 2. IRSA Explained

**IRSA = IAM Roles for Service Accounts.**

A Kubernetes **Service Account** is a non-human identity — it's an object that pods
use to interact with the Kubernetes API and (via IRSA) with AWS.

The magic works like this:

```
1. Pod has a ServiceAccount annotation pointing to an IAM role ARN
2. EKS injects a short-lived JWT token into the pod (projected volume)
3. Pod's AWS SDK calls sts:AssumeRoleWithWebIdentity with that JWT
4. AWS STS verifies the JWT against the EKS OIDC provider
5. STS returns short-lived AWS credentials (15 min TTL)
6. Pod uses those credentials — they auto-rotate
```

Crucially: **no long-lived credentials ever exist**. The pod never has an access key.
The token is auto-rotated by the EKS OIDC provider. This is the most secure pattern.

---

## 3. Setting Up IRSA for audit-service

### Step 1: Create the IAM Role (Terraform)

`terraform/eks/irsa.tf`:
```hcl
# Data source: get the EKS OIDC issuer URL for use in trust policies
data "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_provider_arn = data.aws_iam_openid_connect_provider.eks.arn
  # Extract just the host part: "oidc.eks.ap-south-1.amazonaws.com/id/ABCDEF"
  oidc_provider     = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# IAM role for audit-service
resource "aws_iam_role" "audit_service" {
  name = "cloudcare-k8s-audit-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Pin to the specific ServiceAccount in the specific namespace
          "${local.oidc_provider}:sub" = "system:serviceaccount:prod:audit-service"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "audit_service" {
  name = "cloudcare-k8s-audit-service-policy"
  role = aws_iam_role.audit_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
      # Scope to the specific table ARN — not all DynamoDB tables
      Resource = aws_dynamodb_table.audit_events.arn
    }]
  })
}
```

**Critical detail:** the trust policy's `sub` condition pins to
`system:serviceaccount:prod:audit-service` — the exact namespace and ServiceAccount name.
A pod in `dev:audit-service` **cannot** assume this role.

### Step 2: Create the Kubernetes ServiceAccount

In the Helm chart `helm/audit-service/templates/serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audit-service
  namespace: {{ .Release.Namespace }}
  annotations:
    # This annotation is what IRSA reads
    eks.amazonaws.com/role-arn: {{ .Values.serviceAccount.roleArn }}
```

In `helm/audit-service/values-prod.yaml`:
```yaml
serviceAccount:
  roleArn: "arn:aws:iam::123456789:role/cloudcare-k8s-audit-service"
```

### Step 3: Reference the ServiceAccount in the Deployment

In `helm/audit-service/templates/deployment.yaml`:
```yaml
spec:
  template:
    spec:
      serviceAccountName: audit-service    # ← adds the role annotation to the pod
      containers:
        - name: audit-service
          # No AWS_ env vars needed — SDK picks up credentials automatically
```

That's it. The AWS SDK in the pod automatically detects the injected token and
uses IRSA credentials. No access keys anywhere.

---

## 4. IRSA for All Services

| Service | IAM Permissions | Scope |
|---|---|---|
| patient-service | `secretsmanager:GetSecretValue` | only `cloudcare-k8s/patient-service/db` ARN |
| appointment-service | `secretsmanager:GetSecretValue` | only `cloudcare-k8s/appointment-service/db` ARN |
| audit-service | `dynamodb:PutItem` | only `audit_events` table ARN |
| notification-service | `ses:SendEmail` conditioned on `ses:FromAddress` | only the verified sender |
| external-secrets | `secretsmanager:GetSecretValue` | all `cloudcare-k8s/*` secret ARNs |

---

## 5. External Secrets Operator (ESO)

**The problem:** even with IRSA, you still need to get the database URL into the pod as
an environment variable. The database URL is in AWS Secrets Manager. How does it get
into the pod?

**Option 1 — Application code reads Secrets Manager:**
```python
import boto3
client = boto3.client("secretsmanager")
secret = client.get_secret_value(SecretId="cloudcare-k8s/patient-service/db")
DATABASE_URL = json.loads(secret["SecretString"])["DATABASE_URL"]
```
This works but pollutes every application with AWS SDK calls. If you ever move off AWS,
you have to change the app code.

**Option 2 — External Secrets Operator (the right way):**
ESO runs as a pod in your cluster. You create an `ExternalSecret` resource that says
"pull this key from Secrets Manager and store it as a Kubernetes Secret". Your app
just reads a normal environment variable — it has no idea where the value came from.

```
ExternalSecret manifest
       │
       ▼
External Secrets Operator pod
  → reads cloudcare-k8s/patient-service/db from Secrets Manager (via IRSA)
  → creates/updates Kubernetes Secret "patient-service-db-secret"
       │
       ▼
Kubernetes Secret
  → mounted as env var DATABASE_URL in the patient-service pod
       │
       ▼
patient-service app reads DATABASE_URL from environment
```

### 5.1 Install ESO (via Terraform/Helm)

In `terraform/platform/eso.tf`:
```hcl
resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "external-secrets"
  create_namespace = true
  version    = "0.9.x"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }
}
```

### 5.2 Create the ClusterSecretStore

This tells ESO where Secrets Manager is (which region and how to authenticate):

`k8s/base/secret-store.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

### 5.3 Create the ExternalSecret

This is the manifest that says "pull THIS secret from Secrets Manager":

`helm/patient-service/templates/externalsecret.yaml`:
```yaml
{{- if .Values.externalSecret.enabled }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: patient-service-db-secret
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: {{ .Values.externalSecret.refreshInterval }}

  secretStoreRef:
    name: {{ .Values.externalSecret.secretStoreRef.name }}
    kind: {{ .Values.externalSecret.secretStoreRef.kind }}

  target:
    name: patient-service-db-secret   # name of the K8s Secret to create
    creationPolicy: Owner

  data:
    - secretKey: DATABASE_URL          # key in the K8s Secret
      remoteRef:
        key: {{ .Values.externalSecret.remoteSecretName }}   # secret name in Secrets Manager
        property: DATABASE_URL         # field inside the JSON secret value
{{- end }}
```

When you apply this, ESO:
1. Reads `cloudcare-k8s/patient-service/db` from Secrets Manager
2. Extracts the `DATABASE_URL` field from the JSON
3. Creates a Kubernetes Secret named `patient-service-db-secret` in the `prod` namespace
4. Keeps it in sync — if you rotate the Secrets Manager secret, ESO updates the K8s
   Secret within the `refreshInterval`

The Deployment then uses it exactly as in Doc 03:
```yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: patient-service-db-secret
        key: DATABASE_URL
```

---

## 6. Secret Rotation

One of the most powerful aspects of this setup: if you rotate the database password in
Secrets Manager, ESO detects the change (within `refreshInterval`, e.g. 1 hour) and
updates the Kubernetes Secret. Kubernetes then makes the new value available to pods on
their next restart or environment variable refresh.

For immediate rotation, trigger a pod restart:
```bash
kubectl rollout restart deployment/patient-service -n prod
```

The new pod picks up the updated secret from the Kubernetes Secret, which ESO already
updated from Secrets Manager.

---

## 7. What NOT to Do

Never put real secrets in:
- `values.yaml`, `values-dev.yaml`, `values-prod.yaml` — these are committed to Git
- Kubernetes Secret manifests committed to Git — base64 is NOT encryption
- GitHub Actions environment variables (unless using GitHub Secrets, not variables)
- Docker images (via ENV or COPY)

The only safe sources of secrets for production pods are:
1. External Secrets Operator → Kubernetes Secret → pod env var (this doc)
2. AWS Parameter Store (similar pattern, different service)
3. HashiCorp Vault Agent Injector (enterprise teams)

---

## ✅ Checkpoint

You should be able to explain:

- What is IRSA and why is it better than instance profiles?
- What is the trust policy condition that makes IRSA least-privilege?
- What is the External Secrets Operator and what problem does it solve?
- What is the flow from Secrets Manager to a pod's environment variable?
- Why should you never commit a Kubernetes Secret manifest to Git?
- How does secret rotation work with ESO?

Next: **[08 — Horizontal Pod Autoscaling](08-hpa.md)** — automatically scale pods
based on CPU/memory usage, replacing the ASG instance-refresh from v1.
