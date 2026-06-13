# 07b — Secrets Practice: Every File, Every Line

> **Read 07a first.** This doc writes all Terraform (IRSA roles) and Kubernetes
> YAML (ExternalSecret, ClusterSecretStore, ServiceAccount) with every line explained.

---

## 1. Terraform: IRSA roles for each service

These go in the **platform stack** (`terraform/platform/irsa.tf`).

```hcl
# ── Read OIDC provider info from the eks stack ────────────────────────────────
# (already available via remote_state.tf)
# data.terraform_remote_state.eks.outputs.oidc_provider_arn
# data.terraform_remote_state.eks.outputs.oidc_provider_url

locals {
  oidc_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_url = data.terraform_remote_state.eks.outputs.oidc_provider_url
  # shorthand so the trust policies below are readable
}

# ── Helper: a function that builds the trust policy for any ServiceAccount ────
# We use it 3 times (audit, notification, ESO) — avoids copy-paste
locals {
  irsa_trust_policy = { for sa, ns in {
    "audit-service"        = "prod"
    "notification-service" = "prod"
    "eso-service-account"  = "external-secrets"    # ESO runs in its own namespace
  } : sa => jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:${ns}:${sa}"
          # "system:serviceaccount:prod:audit-service"
          # only the exact ServiceAccount in the exact namespace can assume this role
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })}
}

# ── IAM Role: audit-service ───────────────────────────────────────────────────
resource "aws_iam_role" "audit_service" {
  name               = "cloudcare-k8s-audit-service"
  assume_role_policy = local.irsa_trust_policy["audit-service"]
}

resource "aws_iam_role_policy" "audit_service" {
  name = "cloudcare-k8s-audit-service-policy"
  role = aws_iam_role.audit_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",       # write audit events
        "dynamodb:GetItem",       # read back for debugging
        "dynamodb:CreateTable",   # audit-service creates the table if missing
        "dynamodb:DescribeTable", # check table exists before writing
      ]
      Resource = "arn:aws:dynamodb:ap-south-1:670794226080:table/cloudcare-events"
      # scope to EXACTLY this table — not all DynamoDB tables in the account
    }]
  })
}

# ── IAM Role: notification-service ───────────────────────────────────────────
resource "aws_iam_role" "notification_service" {
  name               = "cloudcare-k8s-notification-service"
  assume_role_policy = local.irsa_trust_policy["notification-service"]
}

resource "aws_iam_role_policy" "notification_service" {
  name = "cloudcare-k8s-notification-service-policy"
  role = aws_iam_role.notification_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      # SES doesn't support resource-level ARN scoping for SendEmail
      # restrict instead by verified email identities (configured in SES console)
    }]
  })
}

# ── IAM Role: ESO (External Secrets Operator) ─────────────────────────────────
# ESO needs to read from Secrets Manager on behalf of patient and appointment services
resource "aws_iam_role" "eso" {
  name               = "cloudcare-k8s-eso"
  assume_role_policy = local.irsa_trust_policy["eso-service-account"]
}

resource "aws_iam_role_policy" "eso" {
  name = "cloudcare-k8s-eso-policy"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",    # read the actual secret value
        "secretsmanager:DescribeSecret",    # check secret exists before reading
      ]
      Resource = [
        "arn:aws:secretsmanager:ap-south-1:670794226080:secret:cloudcare-k8s/patient-service/*",
        "arn:aws:secretsmanager:ap-south-1:670794226080:secret:cloudcare-k8s/appointment-service/*",
        # scope to ONLY the secrets for these two services — not all secrets in the account
      ]
    }]
  })
}

# ── Outputs: ARNs so Helm charts can reference them ───────────────────────────
output "audit_service_role_arn" {
  value = aws_iam_role.audit_service.arn
  # used in: helm/audit-service/values-prod.yaml → serviceAccount.annotations
}

output "notification_service_role_arn" {
  value = aws_iam_role.notification_service.arn
}

output "eso_role_arn" {
  value = aws_iam_role.eso.arn
  # used in: platform/eso.tf → Helm release set value
}
```

---

## 2. Terraform: install ESO via Helm

In `terraform/platform/eso.tf`:

```hcl
# Install External Secrets Operator into the cluster
resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"    # ESO lives in its own namespace
  create_namespace = true                  # create it if it doesn't exist
  version          = "0.9.11"             # pin the version for reproducibility

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
    # annotate the ESO ServiceAccount with the IRSA role ARN
    # the backslash escapes the dot so Helm treats it as a key with a dot,
    # not as nested YAML (eks → amazonaws → com/role-arn)
  }
  # After install, ESO watches all ExternalSecret resources in the cluster
  # and syncs them into Kubernetes Secrets automatically
}
```

---

## 3. Kubernetes: ClusterSecretStore

This YAML tells ESO "use AWS Secrets Manager in ap-south-1".
One per cluster — apply it once.

`k8s/base/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager    # referenced by all ExternalSecrets below
spec:
  provider:
    aws:
      service: SecretsManager    # use AWS Secrets Manager (not Parameter Store)
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets    # ESO's own ServiceAccount (has IRSA role)
            namespace: external-secrets
            # ESO uses its IRSA credentials to authenticate with Secrets Manager
            # your microservice pods never touch Secrets Manager directly
```

Apply after ESO is installed:
```bash
kubectl apply -f k8s/base/cluster-secret-store.yaml

# verify it connected successfully:
kubectl get clustersecretstore aws-secrets-manager
# STATUS should be: Valid
```

---

## 4. Helm chart updates: ServiceAccount + ExternalSecret

For IRSA to work, the Deployment must reference a ServiceAccount that has
the IRSA annotation. We add this to the Helm charts.

### 4a. Add ServiceAccount template

Create `helm/audit-service/templates/serviceaccount.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "audit-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  annotations:
    {{- if .Values.serviceAccount.roleArn }}
    eks.amazonaws.com/role-arn: {{ .Values.serviceAccount.roleArn }}
    # this annotation is what IRSA reads
    # EKS webhook sees this → injects AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN into pod
    # boto3 picks up those env vars automatically → no credential code needed
    {{- end }}
```

### 4b. Update deployment.yaml to reference the ServiceAccount

In `helm/audit-service/templates/deployment.yaml`, add `serviceAccountName` to the pod spec:

```yaml
spec:
  template:
    spec:
      serviceAccountName: {{ include "audit-service.fullname" . }}
      # tells Kubernetes to run this pod AS the ServiceAccount above
      # without this line, the pod uses the "default" ServiceAccount
      # which has no IRSA annotation → no AWS credentials injected
      containers:
        ...
```

### 4c. Update values files

In `helm/audit-service/values.yaml`:
```yaml
serviceAccount:
  roleArn: ""    # empty by default (dev uses local DynamoDB, no IRSA needed)
```

In `helm/audit-service/values-prod.yaml`:
```yaml
serviceAccount:
  roleArn: "arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service"
  # the ARN from irsa.tf output — paste the actual ARN after terraform apply
```

Do the same for **notification-service** (`cloudcare-k8s-notification-service` role ARN).

**patient-service and appointment-service** don't need IRSA — ESO handles their secrets.
They just need the ExternalSecret (see below).

---

## 5. Helm chart: ExternalSecret template

The `externalsecret.yaml` file is already in the Helm charts. Here is every line explained:

`helm/patient-service/templates/externalsecret.yaml`:

```yaml
{{- if .Values.externalSecret.enabled }}
# only render this file when externalSecret.enabled=true
# in dev: disabled (we use a plain K8s Secret or env vars)
# in prod: enabled (ESO pulls from Secrets Manager)

apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "patient-service.fullname" . }}-db
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: 1h    # ESO re-reads from Secrets Manager every hour
  # if you rotate the DB password in Secrets Manager, pods get the new password within 1 hour
  # without manual intervention

  secretStoreRef:
    name: aws-secrets-manager    # use the ClusterSecretStore we created above
    kind: ClusterSecretStore

  target:
    name: {{ include "patient-service.fullname" . }}-db-secret
    # name of the Kubernetes Secret that ESO will create
    # this is the Secret your Deployment references in envFrom or env.valueFrom

  data:
    - secretKey: DATABASE_URL           # the key inside the created K8s Secret
      remoteRef:
        key: cloudcare-k8s/patient-service/db    # the path in Secrets Manager
        # this is the secret name from secrets.tf: aws_secretsmanager_secret.patient_db
        property: DATABASE_URL          # the field inside the JSON value
        # Secrets Manager stores: { "DATABASE_URL": "postgresql://..." }
        # property picks out the DATABASE_URL field from that JSON
{{- end }}
```

In `values.yaml`:
```yaml
externalSecret:
  enabled: false    # default off
```

In `values-prod.yaml`:
```yaml
externalSecret:
  enabled: true     # turns on the ExternalSecret in prod
```

Do the same for **appointment-service** (pointing to `cloudcare-k8s/appointment-service/db`).

---

## 6. Update Deployment to read from the K8s Secret

In `helm/patient-service/templates/deployment.yaml`, the DATABASE_URL env var
should read from the Secret that ESO created:

```yaml
containers:
  - name: patient-service
    env:
      {{- if .Values.externalSecret.enabled }}
      - name: DATABASE_URL
        valueFrom:
          secretKeyRef:
            name: {{ include "patient-service.fullname" . }}-db-secret
            # this is the K8s Secret that ESO created
            key: DATABASE_URL
      {{- else }}
      - name: DATABASE_URL
        value: {{ .Values.databaseUrl | quote }}
        # dev: use plain value from values-dev.yaml (points to local postgres)
      {{- end }}
```

In prod: `DATABASE_URL` comes from the ESO-synced Secret.
In dev: `DATABASE_URL` comes from `values-dev.yaml` directly (no ESO, no Secrets Manager).

---

## 7. Apply order (when EKS is running)

```bash
# 1. Deploy ESO via terraform (platform stack)
cd terraform/platform && terraform apply

# 2. Apply the ClusterSecretStore
kubectl apply -f k8s/base/cluster-secret-store.yaml

# 3. Verify ESO connected to Secrets Manager
kubectl get clustersecretstore aws-secrets-manager
# should show: READY=True

# 4. Deploy services with prod values — ExternalSecrets are created automatically
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-prod.yaml \
  --namespace prod --create-namespace

# 5. Watch ESO sync the secret
kubectl get externalsecret -n prod
# NAME                          STORE                 REFRESH INTERVAL   STATUS
# patient-service-db            aws-secrets-manager   1h                 SecretSynced

# 6. Verify the K8s Secret was created
kubectl get secret patient-service-db-secret -n prod
kubectl describe secret patient-service-db-secret -n prod
# shows the keys (not the values — K8s doesn't show secret values in describe)
```

---

## ✅ Checkpoint — done when:

- [ ] `irsa.tf` has roles for audit-service, notification-service, and ESO
- [ ] `eso.tf` installs ESO with the IRSA role annotation
- [ ] `cluster-secret-store.yaml` created in `k8s/base/`
- [ ] audit-service and notification-service Helm charts have `serviceaccount.yaml`
- [ ] patient-service and appointment-service have `externalsecret.yaml` enabled in prod values
- [ ] You can explain: why does ESO need IRSA but patient-service does not?
- [ ] You can explain: what happens to DATABASE_URL if you rotate the password in Secrets Manager?
- [ ] You can explain: why is `system:serviceaccount:prod:audit-service` in the trust policy?

Next: **[08a — HPA Concepts](08a-hpa-concepts.md)** — understand how Kubernetes
automatically scales pods up and down based on CPU load.
