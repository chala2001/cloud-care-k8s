# 04 — Helm Charts

> **Goal of this doc:** understand what Helm is, why it's the industry standard for
> deploying applications on Kubernetes, and write a complete Helm chart for
> patient-service with dev and prod value overrides.

All work in this doc runs on **minikube — zero cost.**

---

## 1. The Problem Helm Solves

In Doc 03, you wrote raw YAML manifests. Imagine you have dev and prod environments.
In dev you want 1 replica, in prod you want 3. Your Docker image tag changes with
every deployment. Your secrets come from different sources per environment.

Without Helm, you'd have two near-identical copies of every YAML file — one for dev,
one for prod. Every change requires editing both files. That's error-prone.

**Helm** is the package manager for Kubernetes. You write a **chart** — a set of
templates with placeholder variables — and provide different **values files** for
different environments. Helm fills in the placeholders and produces final YAML.

```
Helm chart (templates)  +  values-dev.yaml   →  dev deployment (1 replica)
Helm chart (templates)  +  values-prod.yaml  →  prod deployment (3 replicas)
```

> 🧠 **Think of Helm like a template engine for Kubernetes.** The chart is the
> structure; the values file is the configuration. Same structure, different config
> per environment.

---

## 2. Helm Concepts

### Chart

A chart is a directory with a specific structure:

```
patient-service/
├── Chart.yaml          ← chart metadata (name, version, description)
├── values.yaml         ← default values
├── values-dev.yaml     ← dev overrides
├── values-prod.yaml    ← prod overrides
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    ├── externalsecret.yaml
    └── _helpers.tpl    ← reusable template snippets
```

### Release

When you install a chart onto a cluster, Helm creates a **release** — a named
instance of the chart. You can have the release `patient-service` in the `dev`
namespace and another `patient-service` release in `prod`, both using the same
chart but different values.

### helm Commands You'll Use Every Day

```bash
# Install a chart (first time)
helm install <release-name> <chart-path> -f values-dev.yaml -n <namespace>

# Upgrade an existing release (also installs if not present)
helm upgrade --install <release-name> <chart-path> -f values-dev.yaml -n <namespace>

# List all releases in a namespace
helm list -n dev

# See the status of a release
helm status patient-service -n dev

# See the full rendered YAML without applying it (great for debugging)
helm template <release-name> <chart-path> -f values-dev.yaml

# Roll back to a previous version
helm rollback patient-service 1 -n dev

# Uninstall a release
helm uninstall patient-service -n dev

# Show the history of a release (all revisions)
helm history patient-service -n dev
```

---

## 3. Writing the Chart

### 3.1 Chart.yaml

`helm/patient-service/Chart.yaml`:
```yaml
apiVersion: v2
name: patient-service
description: CloudCare patient management microservice
type: application
version: 0.1.0        # chart version (bumped when the chart changes)
appVersion: "1.0.0"   # application version (informational)
```

### 3.2 values.yaml (Default Values)

`helm/patient-service/values.yaml`:
```yaml
# Number of pod replicas
replicaCount: 1

# Docker image configuration
image:
  repository: ""               # set per-environment or via --set
  tag: "latest"
  pullPolicy: IfNotPresent

# Service configuration
service:
  type: ClusterIP
  port: 8001

# Resource requests and limits
resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "128Mi"
    cpu: "200m"

# Health check paths
healthCheck:
  path: /health
  port: 8001
  initialDelaySeconds: 5
  periodSeconds: 10

# Environment variables (non-secret)
env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "INFO"

# HPA (Horizontal Pod Autoscaler) — disabled by default
hpa:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

# External Secrets configuration
externalSecret:
  enabled: false           # only in production (Doc 07)
  secretStoreRef:
    name: aws-secrets-store
    kind: ClusterSecretStore
  refreshInterval: "1h"
  remoteSecretName: ""     # e.g. cloudcare-k8s/patient-service/db

# Database URL — for local dev only; in prod this comes from ExternalSecret
databaseUrl: ""
```

### 3.3 values-dev.yaml (Dev Overrides)

`helm/patient-service/values-dev.yaml`:
```yaml
replicaCount: 1

image:
  repository: "patient-service"
  tag: "local"
  pullPolicy: Never        # use locally built minikube image

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "DEBUG"
  DATABASE_URL: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"

hpa:
  enabled: false           # no HPA in dev — save resources

externalSecret:
  enabled: false           # use plain K8s secret in dev
```

### 3.4 values-prod.yaml (Prod Overrides)

`helm/patient-service/values-prod.yaml`:
```yaml
replicaCount: 2

image:
  repository: "123456789.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service"
  tag: "latest"            # overridden by CI with git SHA: --set image.tag=abc1234
  pullPolicy: Always

resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "WARNING"

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70

externalSecret:
  enabled: true
  remoteSecretName: "cloudcare-k8s/patient-service/db"
```

---

## 4. Writing the Templates

Helm templates use Go's `text/template` syntax. The key syntax:

- `{{ .Values.replicaCount }}` — reads a value from values.yaml
- `{{ .Release.Name }}` — the release name passed to `helm install`
- `{{ .Release.Namespace }}` — the namespace
- `{{- if .Values.hpa.enabled }}` — conditional block
- `{{- end }}` — end of conditional or range

### 4.1 _helpers.tpl

`helm/patient-service/templates/_helpers.tpl`:
```
{{/*
Expand the name of the chart.
*/}}
{{- define "patient-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources in this chart.
*/}}
{{- define "patient-service.labels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by the Deployment and Service.
*/}}
{{- define "patient-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### 4.2 deployment.yaml

`helm/patient-service/templates/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "patient-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "patient-service.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: patient-service
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.port }}
          env:
            {{- range $key, $val := .Values.env }}
            - name: {{ $key }}
              value: {{ $val | quote }}
            {{- end }}
            {{- if not .Values.externalSecret.enabled }}
            - name: DATABASE_URL
              value: {{ .Values.databaseUrl | quote }}
            {{- else }}
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: patient-service-db-secret
                  key: DATABASE_URL
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: {{ .Values.healthCheck.path }}
              port: {{ .Values.healthCheck.port }}
            initialDelaySeconds: {{ .Values.healthCheck.initialDelaySeconds }}
            periodSeconds: {{ .Values.healthCheck.periodSeconds }}
          livenessProbe:
            httpGet:
              path: {{ .Values.healthCheck.path }}
              port: {{ .Values.healthCheck.port }}
            initialDelaySeconds: 15
            periodSeconds: 20
```

### 4.3 service.yaml

`helm/patient-service/templates/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "patient-service.selectorLabels" . | nindent 4 }}
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.port }}
```

### 4.4 hpa.yaml

`helm/patient-service/templates/hpa.yaml`:
```yaml
{{- if .Values.hpa.enabled }}
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
    name: {{ .Release.Name }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
{{- end }}
```

The `{{- if .Values.hpa.enabled }}` and `{{- end }}` mean: **only render this template
if `hpa.enabled` is `true` in values**. So in dev (where HPA is disabled), this file
produces no output at all.

---

## 5. Deploy to minikube with Helm

```bash
# Start minikube and build images
minikube start --cpus=2 --memory=4g
eval $(minikube docker-env)
for svc in patient-service appointment-service audit-service notification-service; do
  (cd services/$svc && docker build -t $svc:local .)
done

# Create the dev namespace
kubectl create namespace dev 2>/dev/null || true

# Deploy patient-service using Helm
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# Check the release
helm list -n dev
# NAME              NAMESPACE  REVISION  STATUS    CHART
# patient-service   dev        1         deployed  patient-service-0.1.0

# Check the pods
kubectl get pods -n dev
# NAME                               READY   STATUS    RESTARTS   AGE
# patient-service-7d9f8b6c9-xk2pq   1/1     Running   0          20s
```

Deploy all four services:
```bash
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-dev.yaml \
    --namespace dev
done
```

---

## 6. Verify: Preview the Rendered YAML

Before deploying, always preview what Helm will generate:

```bash
helm template patient-service ./helm/patient-service -f helm/patient-service/values-dev.yaml
```

This prints the final YAML without applying anything. Use this to:
- Verify placeholders were filled correctly
- Debug unexpected values
- Understand what's actually going to be applied

---

## 7. Rollback

One of Helm's most valuable features: you can roll back to any previous revision.

```bash
# Simulate a bad deploy
helm upgrade patient-service ./helm/patient-service \
  --set image.tag=broken-tag \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# See the history
helm history patient-service -n dev
# REVISION  STATUS      CHART
# 1         superseded  patient-service-0.1.0
# 2         failed      patient-service-0.1.0   ← bad deploy

# Roll back to revision 1
helm rollback patient-service 1 -n dev
# Rollback was a success! Happy Helming!

# History now shows revision 3 = rollback to 1's config
helm history patient-service -n dev
# REVISION  STATUS      CHART
# 1         superseded  patient-service-0.1.0
# 2         superseded  patient-service-0.1.0
# 3         deployed    patient-service-0.1.0   ← this is now live
```

Compare this to CloudCare v1's rollback: find the old AMI, re-tag it as latest, push
it, trigger an instance refresh, wait 5 minutes. With Helm: one command, 30 seconds.

---

## 8. Chart Structure for All Four Services

Each service has its own chart. They follow the same structure — only the values
and image name differ:

```
helm/
├── patient-service/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── hpa.yaml
│       └── externalsecret.yaml
├── appointment-service/   ← same structure, port 8002
├── audit-service/         ← same structure, port 8003
└── notification-service/  ← same structure, port 8004
```

---

## ✅ Checkpoint

You should be able to:

- [ ] Explain what Helm does and why it's better than raw YAML for multiple environments.
- [ ] Read a `values.yaml` and explain each field.
- [ ] Run `helm template` and verify the rendered output.
- [ ] Run `helm upgrade --install` and see a pod deploy.
- [ ] Run `helm rollback` and verify it works.
- [ ] Explain what `{{- if .Values.hpa.enabled }}` does.

Next: **[05 — EKS with Terraform](05-eks-terraform.md)** — provision a real
Kubernetes cluster on AWS. This is where free work ends — EKS costs ~$2.40/day.
