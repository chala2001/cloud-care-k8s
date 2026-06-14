# 04b — Helm Practice: Every File, Every Line

> **Read 04a first.** This doc walks through every file in every chart,
> explains every single line, then deploys all 4 services to minikube with Helm.

---

## 1. What we are building

```
helm/
├── patient-service/       ← chart for patient-service
├── appointment-service/   ← chart for appointment-service
├── audit-service/         ← chart for audit-service (DynamoDB, no postgres)
└── notification-service/  ← chart for notification-service (SES email, no database)
```

Each chart has the same folder structure but different values.
The templates are nearly identical — values make them different.

---

## 2. patient-service chart — every file explained

### Chart.yaml

```yaml
apiVersion: v2          # always "v2" for Helm 3 (the modern version everyone uses)
name: patient-service   # chart name — MUST match the folder name exactly
description: CloudCare patient management microservice  # human-readable description
type: application       # "application" = this chart deploys real running workloads
                        # (the other type is "library" = just helper templates, no workloads)
version: 0.1.0          # the CHART version — bump this number when you change the chart
                        # structure (e.g. add a new template file)
appVersion: "1.0.0"     # your APPLICATION version — informational only, shown in helm list
                        # not used in any template logic
```

### values.yaml

This is the master defaults file. Every variable used in the templates is defined here.

```yaml
replicaCount: 1         # how many pods to run. Overridden to 2 in values-prod.yaml

image:
  repository: ""        # which Docker registry + image name. Empty here — MUST be set
                        # in values-dev.yaml or values-prod.yaml. If blank, deploy fails.
  tag: "latest"         # which version/tag of the image to use
  pullPolicy: IfNotPresent  # IfNotPresent = use locally cached image if available,
                            # only pull from registry if not found locally

service:
  type: ClusterIP       # ClusterIP = only reachable inside the cluster (not from internet)
  port: 8001            # the port this service listens on

resources:
  requests:
    memory: "64Mi"      # Kubernetes GUARANTEES this much RAM to the pod
    cpu: "50m"          # Kubernetes GUARANTEES this much CPU (50 millicores = 5% of one core)
  limits:
    memory: "128Mi"     # pod is KILLED (OOMKilled) if it exceeds this
    cpu: "200m"         # pod is THROTTLED (slowed down) if it exceeds this

healthCheck:
  path: /health         # the URL path Kubernetes hits to check if pod is alive/ready
  port: 8001            # which port to use for health checks
  initialDelaySeconds: 5   # wait 5 seconds after the container starts before first check
  periodSeconds: 10        # after first check, check every 10 seconds

env:                    # non-secret environment variables passed to the container
  DB_SCHEMA: "patients" # tells SQLAlchemy which postgres schema to use
  LOG_LEVEL: "INFO"     # default log verbosity

hpa:
  enabled: false                      # HPA off by default (enabled in values-prod.yaml)
  minReplicas: 1                      # never scale below this number
  maxReplicas: 5                      # never scale above this number
  targetCPUUtilizationPercentage: 70  # scale up when average CPU exceeds 70%

externalSecret:
  enabled: false         # off by default — only prod uses AWS Secrets Manager
  secretStoreRef:
    name: aws-secrets-store   # the ClusterSecretStore resource name (set up in Doc 07)
    kind: ClusterSecretStore
  refreshInterval: "1h"  # how often to re-sync from AWS Secrets Manager
  remoteSecretName: ""   # path in Secrets Manager, e.g. "cloudcare-k8s/patient-service/db"

databaseUrl: ""          # the postgres connection string. Empty here — set in dev values.
                         # In prod, this comes from ExternalSecret (not this variable).
```

### values-dev.yaml

Only lists what differs from values.yaml. Everything not listed is inherited from defaults.

```yaml
image:
  repository: "patient-service"  # local image name — built with: docker build -t patient-service:local
  tag: "local"                   # the :local tag we used when building
  pullPolicy: Never              # NEVER pull from internet. minikube has its own Docker,
                                 # we built the image there — just use it directly

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "DEBUG"             # more verbose logging helps with dev debugging

databaseUrl: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
# patient_svc = the postgres user created by init.sql (has access to patients schema only)
# postgres   = the Service name inside the cluster (Kubernetes DNS resolves this)
# cloudcare  = the database name
# 5432       = postgres port
```

### values-prod.yaml

```yaml
replicaCount: 2         # 2 pods for high availability. If one node fails, the other pod
                        # keeps serving requests while Kubernetes reschedules the failed pod.

image:
  repository: "123456789.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service"
  # full ECR registry URL + image name. The account ID is your AWS account ID.
  tag: "latest"         # this is overridden by CI with the git SHA:
                        # helm upgrade ... --set image.tag=a3f8b2c
  pullPolicy: Always    # always pull from ECR on every deploy. This ensures the latest
                        # image is used even if the tag name is reused.

resources:              # bigger allocations for real production traffic
  requests:
    memory: "128Mi"     # double the dev allocation
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "WARNING"  # only log warnings and errors in prod — less noise

hpa:
  enabled: true         # turn on auto-scaling in prod
  minReplicas: 2        # always keep at least 2 running
  maxReplicas: 6        # allow up to 6 under heavy load
  targetCPUUtilizationPercentage: 70

databaseSecretName: "patient-service-db-secret"
# in prod, DATABASE_URL is read from this Kubernetes Secret (created from Secrets Manager).
# This takes priority over databaseUrl. We do NOT pass the URL via --set because
# Helm mangles connection strings containing "://" and "@" characters.
# The K8s Secret is created manually before helm deploy — see Doc 07 for the procedure.
```

### templates/_helpers.tpl

This file defines reusable label snippets. Other template files `include` them.
Helm recognises files starting with `_` as helpers — it doesn't try to apply them directly.

```
{{/*
"patient-service.name" → produces "patient-service" (trimmed to 63 chars max)
*/}}
{{- define "patient-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
# default: use Chart.Name unless nameOverride is set in values
# trunc 63: Kubernetes names cannot exceed 63 characters
# trimSuffix "-": remove trailing dash if truncation created one

{{/*
"patient-service.labels" → the standard Kubernetes recommended labels
These go on every resource (Deployment, Service, HPA) for observability/filtering
*/}}
{{- define "patient-service.labels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}       # the release name used in helm install
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}  # always "Helm"
{{- end }}

{{/*
"patient-service.selectorLabels" → labels the Deployment uses to FIND its pods
These must match between spec.selector.matchLabels and template.metadata.labels
*/}}
{{- define "patient-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### templates/deployment.yaml

This is the most important template. Read every line carefully.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}             # becomes "patient-service" (from helm install command)
  namespace: {{ .Release.Namespace }}   # becomes "dev" or "prod" (from -n flag)
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
    # include = "paste the labels snippet from _helpers.tpl here"
    # nindent 4 = indent the pasted content by 4 spaces (to match YAML structure)
spec:
  replicas: {{ .Values.replicaCount }}  # 1 in dev, 2 in prod — filled from values
  selector:
    matchLabels:
      {{- include "patient-service.selectorLabels" . | nindent 6 }}
      # the Deployment uses these labels to FIND which pods it manages
      # MUST match the labels in template.metadata.labels below
  template:             # template = what every pod created by this Deployment looks like
    metadata:
      labels:
        {{- include "patient-service.selectorLabels" . | nindent 8 }}
        # every pod gets these labels — matches the selector above
    spec:
      containers:
        - name: patient-service
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          # dev  → "patient-service:local"
          # prod → "123456789.ecr.../patient-service:a3f8b2c"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          # Never (dev) or Always (prod)
          ports:
            - containerPort: {{ .Values.service.port }}   # 8001
          env:
            {{- range $key, $val := .Values.env }}
            # loop over every key-value pair in the env: map from values.yaml
            - name: {{ $key }}            # e.g. DB_SCHEMA
              value: {{ $val | quote }}   # e.g. "patients" (quote adds the quotes)
            {{- end }}
            {{- if .Values.databaseSecretName }}
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.databaseSecretName }}
                  # prod: read DATABASE_URL from this K8s Secret
                  # the Secret was created from AWS Secrets Manager before helm deploy
                  # we use secretKeyRef instead of --set because Helm mangles "://" and "@"
                  key: DATABASE_URL
            {{- else if not .Values.externalSecret.enabled }}
            - name: DATABASE_URL
              value: {{ .Values.databaseUrl | quote }}
              # dev: DATABASE_URL is a plain string in values-dev.yaml
            {{- else }}
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: patient-service-db-secret
                  # ESO path (future): ExternalSecret creates the K8s Secret automatically
                  key: DATABASE_URL
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
            # toYaml converts the resources map to YAML text and pastes it here
            # nindent 12 = indent by 12 spaces to fit inside containers spec
          readinessProbe:
            httpGet:
              path: {{ .Values.healthCheck.path }}  # /health
              port: {{ .Values.healthCheck.port }}  # 8001
            initialDelaySeconds: {{ .Values.healthCheck.initialDelaySeconds }}
            periodSeconds: {{ .Values.healthCheck.periodSeconds }}
            # pod only gets traffic AFTER this passes — zero-downtime rolling updates
          livenessProbe:
            httpGet:
              path: {{ .Values.healthCheck.path }}
              port: {{ .Values.healthCheck.port }}
            initialDelaySeconds: 15   # longer than readiness — app needs more time to start
            periodSeconds: 20
            # pod is restarted if this fails — detects deadlocks and frozen apps
```

### templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}          # "patient-service" — THIS is the DNS name other pods use
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}   # ClusterIP (internal only)
  selector:
    {{- include "patient-service.selectorLabels" . | nindent 4 }}
    # the Service finds pods by matching these labels
    # routes traffic only to pods that have these labels AND are ready
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}        # 8001 — what callers dial (e.g. :8001)
      targetPort: {{ .Values.service.port }}  # 8001 — what the pod actually listens on
      # port and targetPort are the same here but could differ
      # e.g. port: 80, targetPort: 8001 (caller uses :80, pod runs on :8001)
```

### templates/hpa.yaml

```yaml
{{- if .Values.hpa.enabled }}
# Everything inside this block is SKIPPED if hpa.enabled=false (dev)
# When hpa.enabled=true (prod), this entire file produces a valid HPA resource

apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .Release.Name }}       # which Deployment this HPA controls
  minReplicas: {{ .Values.hpa.minReplicas }}   # never go below 2 in prod
  maxReplicas: {{ .Values.hpa.maxReplicas }}   # never go above 6 in prod
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
          # Kubernetes checks: average CPU across ALL patient-service pods
          # if average > 70% → add more pods
          # if average < 70% for 5+ minutes → remove pods (scale down slowly)
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60   # after scaling up, wait 60s before scaling up again
      policies:
        - type: Pods
          value: 2                     # add at most 2 pods per scale event
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300  # wait 5 minutes of low CPU before scaling down
      policies:                        # conservative — avoids removing pods during brief lulls
        - type: Pods
          value: 1                     # remove only 1 pod at a time — very cautious
          periodSeconds: 60
{{- end }}
```

---

## 3. appointment-service differences

The appointment-service chart is identical to patient-service EXCEPT:

**values.yaml differences:**
```yaml
service:
  port: 8002            # different port

env:
  DB_SCHEMA: "appointments"
  PATIENT_SERVICE_URL: "http://patient-service:8001"    # extra — used for sync verification
  AUDIT_SERVICE_URL: "http://audit-service:8003"        # extra — used for async audit call
  NOTIFICATION_SERVICE_URL: "http://notification-service:8004"  # extra — async email call
```

**values-dev.yaml:**
```yaml
databaseUrl: "postgresql://appt_svc:appt_pass@postgres:5432/cloudcare"
# appt_svc = the appointment database user (different from patient_svc)
```

Everything else (templates, structure, hpa, externalSecret) is the same pattern.

---

## 4. audit-service differences

audit-service uses **DynamoDB** instead of postgres. It has completely different
env vars and NO databaseUrl.

**values.yaml key differences:**
```yaml
service:
  port: 8003

env:
  DYNAMODB_TABLE: "audit_events"    # DynamoDB table name (not a postgres schema)
  AWS_DEFAULT_REGION: "ap-south-1"
  LOG_LEVEL: "INFO"

# These two values control DynamoDB Local (dev only)
dynamodbEndpointUrl: ""    # empty by default — set in values-dev.yaml
awsAccessKeyId: ""         # empty by default — set in values-dev.yaml for fake credentials
awsSecretAccessKey: ""
# no databaseUrl at all — audit-service never touches postgres
```

**values-dev.yaml:**
```yaml
dynamodbEndpointUrl: "http://dynamodb-local:8000"
# tells boto3 (AWS Python SDK) to call dynamodb-local instead of real AWS
awsAccessKeyId: "local"       # DynamoDB Local accepts any credentials
awsSecretAccessKey: "local"   # these are fake — DynamoDB Local doesn't validate them
```

**values-prod.yaml:**
```yaml
# dynamodbEndpointUrl NOT SET → boto3 calls real AWS DynamoDB
# awsAccessKeyId NOT SET → pod uses IRSA for real AWS credentials (Doc 07)
# No fake credentials needed in prod
```

**deployment.yaml key difference:**
```yaml
# Instead of the DATABASE_URL block, audit-service has:
{{- if .Values.dynamodbEndpointUrl }}
- name: DYNAMODB_ENDPOINT_URL
  value: {{ .Values.dynamodbEndpointUrl | quote }}   # dev only
- name: AWS_ACCESS_KEY_ID
  value: {{ .Values.awsAccessKeyId | quote }}        # dev only (fake)
- name: AWS_SECRET_ACCESS_KEY
  value: {{ .Values.awsSecretAccessKey | quote }}    # dev only (fake)
{{- end }}
# if dynamodbEndpointUrl is empty (prod), none of these env vars are added
# prod pods get real AWS credentials via IRSA automatically
```

---

## 5. notification-service differences

notification-service has **no database at all**. It only needs `LOCAL_DEV=true`
in dev to log emails to console instead of calling real AWS SES.

**values.yaml key differences:**
```yaml
service:
  port: 8004

env:
  SES_FROM_ADDRESS: "noreply@cloudcare.local"   # the From: address on emails
  AWS_DEFAULT_REGION: "ap-south-1"
  LOG_LEVEL: "INFO"

localDev: ""    # empty string by default — set to "true" in values-dev.yaml
# no databaseUrl, no dynamodbEndpointUrl — notification-service has no database
```

**values-dev.yaml:**
```yaml
localDev: "true"   # makes the service log emails to the pod console instead of SES
                   # you verify it worked with: kubectl logs deployment/notification-service
```

**values-prod.yaml:**
```yaml
env:
  SES_FROM_ADDRESS: "noreply@cloudcare.com"   # real verified SES sender domain
# localDev NOT set → real AWS SES is used → emails actually sent
# Pod uses IRSA for SES permission (Doc 07)
```

**deployment.yaml key difference:**
```yaml
# Instead of DATABASE_URL, notification-service has:
{{- if .Values.localDev }}
- name: LOCAL_DEV
  value: {{ .Values.localDev | quote }}   # only added when localDev is set ("true" in dev)
{{- end }}
# in prod: LOCAL_DEV env var is not present → service calls real SES
```

---

## 6. Deploy to minikube

### Step 1 — build images inside minikube

```bash
# Point your terminal's Docker at minikube's Docker daemon
# (this makes images you build available inside the cluster)
eval $(minikube docker-env)

# Build all 4 images
for svc in patient-service appointment-service audit-service notification-service; do
  echo "Building $svc..."
  (cd services/$svc && docker build -t $svc:local .)
done
```

### Step 2 — deploy with Helm (dev — minikube)

```bash
cd /home/chalaka/cloud-care-both/cloud-care-k8s

# Make sure dev namespace exists
kubectl create namespace dev 2>/dev/null || true
# 2>/dev/null suppresses the "already exists" error if namespace already exists
# || true makes the command always succeed (not fail the script)

# Deploy all 4 services using their dev values
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-dev.yaml \
    --namespace dev
done

# upgrade --install = install if not exists, upgrade if already installed
# $svc = the release name (e.g. "patient-service")
# ./helm/$svc = path to the chart folder
# -f values-dev.yaml = use dev values
# --namespace dev = deploy into the dev namespace
```

### Deploy with Helm (prod — EKS)

In prod, images are tagged with the git SHA (not `:latest`) and secrets come from K8s Secrets.
See Doc 07 for the full secret creation procedure before running this.

```bash
cd /home/chalaka/cloud-care-both/cloud-care-k8s

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1
SHA=$(git rev-parse --short HEAD)    # use git SHA for immutable, traceable image tags

# Build and push each image to ECR
for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  ( cd services/$svc && docker build -t "$ECR:$SHA" . && docker push "$ECR:$SHA" )
done

# Deploy with prod values — secrets already exist as K8s Secrets, image tag is the git SHA
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.tag="$SHA" \
    --namespace prod --create-namespace
done
```

### Step 3 — preview before deploying (always do this first)

```bash
# See what Helm will actually send to Kubernetes — without applying anything
helm template patient-service ./helm/patient-service -f helm/patient-service/values-dev.yaml

# Good checks:
# - replicas: 1 (not 2)
# - image: patient-service:local
# - imagePullPolicy: Never
# - HPA: no HPA section in output (because hpa.enabled=false)
```

### Step 4 — verify

```bash
# See all Helm releases in dev
helm list -n dev
# NAME                  NAMESPACE  REVISION  STATUS    CHART
# appointment-service   dev        1         deployed  appointment-service-0.1.0
# audit-service         dev        1         deployed  audit-service-0.1.0
# notification-service  dev        1         deployed  notification-service-0.1.0
# patient-service       dev        1         deployed  patient-service-0.1.0

# See pods
kubectl get pods -n dev
# All should show 1/1 Running
```

---

## 7. Helm commands reference

```bash
# Preview rendered YAML (no apply)
helm template <release> ./helm/<chart> -f values-dev.yaml

# Deploy (install or upgrade)
helm upgrade --install <release> ./helm/<chart> -f values-dev.yaml -n <namespace>

# List all releases
helm list -n dev

# Full version history of a release
helm history patient-service -n dev
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         deployed    Upgrade complete  ← currently running

# Roll back to a previous revision
helm rollback patient-service 1 -n dev
# creates revision 3 = same config as revision 1

# See what values are currently deployed
helm get values patient-service -n dev

# Delete a release (removes all K8s resources the chart created)
helm uninstall patient-service -n dev
```

---

## 8. Simulate a bad deploy and roll back

```bash
# "Deploy" a broken image tag
helm upgrade patient-service ./helm/patient-service \
  --set image.tag=does-not-exist \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# Pod will be in ImagePullBackOff — image doesn't exist
kubectl get pods -n dev

# Check history
helm history patient-service -n dev
# REVISION  STATUS
# 1         superseded
# 2         failed       ← the bad deploy

# Roll back instantly
helm rollback patient-service 1 -n dev

# Check pods again — old version restored
kubectl get pods -n dev
# patient-service back to Running with the original image
```

---

## ✅ Checkpoint — you are done with Doc 04 when:

- [ ] `helm list -n dev` shows all 4 releases with `STATUS=deployed`
- [ ] `helm template patient-service ./helm/patient-service -f values-dev.yaml` shows `replicas: 1` and `image: patient-service:local`
- [ ] All 4 pods are `1/1 Running` after `helm upgrade --install`
- [ ] You can explain what `{{- if .Values.hpa.enabled }}` does
- [ ] You can explain why `values-dev.yaml` is small (only lists differences)
- [ ] `helm rollback` works and restores the previous version

Next: **[05 — EKS with Terraform](05-eks-terraform.md)** — provision a real
Kubernetes cluster on AWS. **This costs money (~$0.10/hr). Only run when ready.**
