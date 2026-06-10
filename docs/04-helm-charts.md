# 04 — Helm Charts

> **Goal:** understand what Helm is, write a chart for patient-service, and deploy
> it to minikube with separate dev and prod values.

All work in this doc runs on **minikube — zero cost.**

---

## 1. What is Helm and why do we need it?

You now have raw YAML files from Doc 03. They work — but there is a problem.

patient-service needs to run in **dev** and **prod**. The differences between them:

| Setting | Dev | Prod |
|---|---|---|
| Replicas | 1 | 2 |
| Image tag | `local` | `abc1234` (git SHA) |
| Log level | DEBUG | WARNING |
| HPA | off | on |
| Secrets | plain K8s Secret | AWS Secrets Manager |

Without Helm you need **two full YAML files** for patient-service — one for dev, one
for prod. For 4 services that's 8 files. Change one setting → edit 8 files. Easy to
make mistakes and let files drift out of sync.

**Helm solves this with templates + values files.**

> Think of it like a job application form. The form (template) never changes.
> You fill in different details (values) for different applicants (environments).
> Same form, different answers, different output.

```
template + values-dev.yaml   →  dev Kubernetes YAML  (1 replica, local image)
template + values-prod.yaml  →  prod Kubernetes YAML (2 replicas, ECR image)
```

---

## 2. Helm vocabulary — 4 words to know

| Word | Plain meaning |
|---|---|
| **Chart** | A folder with your templates + values files |
| **Values** | The variables that fill in the template blanks |
| **Release** | One deployed instance of a chart. "patient-service in dev" is one release, "patient-service in prod" is another |
| **Render** | Helm fills in the blanks and produces final plain YAML |

---

## 3. Chart folder structure

```
helm/patient-service/
├── Chart.yaml           ← identity card: name, version
├── values.yaml          ← default values (fallback for anything not in dev/prod files)
├── values-dev.yaml      ← only the things that differ in dev
├── values-prod.yaml     ← only the things that differ in prod
└── templates/
    ├── _helpers.tpl     ← reusable name/label snippets (used by all templates)
    ├── deployment.yaml  ← Deployment template with {{ placeholders }}
    ├── service.yaml     ← Service template
    └── hpa.yaml         ← HPA template (skipped entirely if hpa.enabled=false)
```

---

## 4. Chart.yaml — the identity card

`helm/patient-service/Chart.yaml`:
```yaml
apiVersion: v2             # always v2 for Helm 3 (the modern version)
name: patient-service      # chart name — must match the folder name
description: CloudCare patient management microservice
type: application          # "application" = deploys real workloads
version: 0.1.0             # chart version — bump when you change the chart structure
appVersion: "1.0.0"        # your app version — informational, shown in helm list output
```

---

## 5. values.yaml — the defaults

Every variable used in the templates is defined here with a safe default. The dev/prod
files only need to list what they want to **change** — everything else falls back here.

`helm/patient-service/values.yaml`:
```yaml
replicaCount: 1            # how many pods to run

image:
  repository: ""           # which Docker image — empty, must be set per environment
  tag: "latest"            # which version of the image
  pullPolicy: IfNotPresent # only pull the image if not already on the node

service:
  type: ClusterIP          # ClusterIP = internal only, not reachable from outside cluster
  port: 8001               # port this service listens on

resources:
  requests:
    memory: "64Mi"         # minimum RAM Kubernetes guarantees to this pod
    cpu: "50m"             # minimum CPU (50m = 0.05 of one CPU core, i.e. 5%)
  limits:
    memory: "128Mi"        # maximum RAM — pod is killed if it goes over this
    cpu: "200m"            # maximum CPU — pod is throttled if it goes over this

healthCheck:
  path: /health            # URL Kubernetes hits to check if the pod is ready
  port: 8001
  initialDelaySeconds: 5   # wait 5s after pod starts before first check
  periodSeconds: 10        # then check every 10s

env:                       # non-secret config passed as environment variables
  DB_SCHEMA: "patients"
  LOG_LEVEL: "INFO"

hpa:
  enabled: false                       # HPA off by default
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70   # scale up when CPU goes above this %

externalSecret:
  enabled: false           # off by default — only prod pulls from AWS Secrets Manager
  secretStoreRef:
    name: aws-secrets-store
    kind: ClusterSecretStore
  refreshInterval: "1h"
  remoteSecretName: ""     # e.g. cloudcare-k8s/patient-service/db

databaseUrl: ""            # dev only — in prod this comes from ExternalSecret (Doc 07)
```

---

## 6. values-dev.yaml — dev overrides

Only lists what is **different** from values.yaml. Helm merges this on top of the
defaults — anything not listed here is inherited from values.yaml.

`helm/patient-service/values-dev.yaml`:
```yaml
image:
  repository: "patient-service"  # local image built with minikube docker-env
  tag: "local"                   # the :local tag
  pullPolicy: Never              # never pull from internet — use local image only

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "DEBUG"             # verbose logging in dev

databaseUrl: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
```

---

## 7. values-prod.yaml — prod overrides

`helm/patient-service/values-prod.yaml`:
```yaml
replicaCount: 2            # 2 pods for high availability

image:
  repository: "123456789.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service"
  tag: "latest"            # CI pipeline overrides this with git SHA: --set image.tag=abc1234
  pullPolicy: Always       # always pull fresh from ECR on every deploy

resources:                 # larger resources for real prod traffic
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"

env:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "WARNING"     # less noisy in prod

hpa:
  enabled: true            # auto-scale on in prod
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70

externalSecret:
  enabled: true            # pull DATABASE_URL from AWS Secrets Manager (Doc 07)
  remoteSecretName: "cloudcare-k8s/patient-service/db"
```

---

## 8. Templates — YAML with blanks

Helm fills in `{{ }}` placeholders when you run `helm upgrade --install`.

**Three things to understand:**

```
{{ .Values.replicaCount }}          read a value from values.yaml
{{ .Release.Name }}                 the release name you typed in the helm command
{{- if .Values.hpa.enabled }}       only render this block if hpa.enabled is true
{{- end }}                          close the if block
{{- range $k, $v := .Values.env }}  loop over every item in the env map
```

The `-` in `{{-` strips blank lines to keep the output YAML clean.

### templates/_helpers.tpl

This file defines reusable label snippets that all other templates import. You do not
need to edit it — just know it exists so you understand `include` in the templates.

`helm/patient-service/templates/_helpers.tpl`:
```
{{- define "patient-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels added to every resource */}}
{{- define "patient-service.labels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels used by Deployment and Service to find their pods */}}
{{- define "patient-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "patient-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### templates/deployment.yaml

`helm/patient-service/templates/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}               # becomes "patient-service"
  namespace: {{ .Release.Namespace }}     # becomes "dev" or "prod"
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}  # paste labels from _helpers.tpl
spec:
  replicas: {{ .Values.replicaCount }}    # 1 in dev, 2 in prod
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
          # dev  → "patient-service:local"
          # prod → "123...ecr.amazonaws.com/...:abc1234"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.port }}   # 8001
          env:
            {{- range $key, $val := .Values.env }}        # loop: one env var per item
            - name: {{ $key }}                            # e.g. DB_SCHEMA
              value: {{ $val | quote }}                   # e.g. "patients"
            {{- end }}
            {{- if not .Values.externalSecret.enabled }}
            - name: DATABASE_URL
              value: {{ .Values.databaseUrl | quote }}    # dev: plain value in YAML
            {{- else }}
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:                             # prod: read from K8s Secret
                  name: patient-service-db-secret
                  key: DATABASE_URL
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}  # paste resources block as-is
          readinessProbe:                                  # pod only gets traffic after this passes
            httpGet:
              path: {{ .Values.healthCheck.path }}
              port: {{ .Values.healthCheck.port }}
            initialDelaySeconds: {{ .Values.healthCheck.initialDelaySeconds }}
            periodSeconds: {{ .Values.healthCheck.periodSeconds }}
          livenessProbe:                                   # pod is restarted if this fails
            httpGet:
              path: {{ .Values.healthCheck.path }}
              port: {{ .Values.healthCheck.port }}
            initialDelaySeconds: 15
            periodSeconds: 20
```

### templates/service.yaml

`helm/patient-service/templates/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}              # "patient-service" — other pods use this name
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}       # ClusterIP — internal only
  selector:
    {{- include "patient-service.selectorLabels" . | nindent 4 }}
    # routes traffic to pods that have these labels (i.e. the Deployment's pods)
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}        # port callers dial (8001)
      targetPort: {{ .Values.service.port }}  # port on the pod (also 8001)
```

### templates/hpa.yaml

`helm/patient-service/templates/hpa.yaml`:
```yaml
{{- if .Values.hpa.enabled }}   # if hpa.enabled=false, this entire file produces NO output
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
    name: {{ .Release.Name }}            # watches THIS deployment's CPU
  minReplicas: {{ .Values.hpa.minReplicas }}   # never go below this
  maxReplicas: {{ .Values.hpa.maxReplicas }}   # never go above this
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
          # when average CPU across all pods exceeds this %, add more pods
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60    # wait 60s before scaling up again (prevent thrashing)
      policies:
        - type: Pods
          value: 2                      # add max 2 pods per scale event
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5 min before removing pods
      policies:
        - type: Pods
          value: 1                      # remove max 1 pod at a time (cautious)
          periodSeconds: 60
{{- end }}
```

---

## 9. Commands you will use every day

```bash
# Preview the final YAML Helm generates — does NOT apply anything to the cluster
# Always run this first to verify your values are filling in correctly
helm template patient-service ./helm/patient-service -f helm/patient-service/values-dev.yaml

# Deploy (installs if first time, upgrades if already installed)
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# Same command for prod — only the values file and namespace change
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-prod.yaml \
  --namespace prod

# List all deployed releases
helm list -n dev

# See all versions ever deployed (each deploy = new revision number)
helm history patient-service -n dev

# Roll back to a previous version — one command, ~30 seconds
helm rollback patient-service 1 -n dev

# Delete a release
helm uninstall patient-service -n dev
```

**Why rollback is so much faster than CloudCare v1:**
- v1: find old AMI → re-tag → push → trigger instance refresh → wait 5–10 min
- v2: `helm rollback patient-service 1 -n dev` → done in ~30 seconds

---

## 10. Deploy to minikube

```bash
# Build images inside minikube
eval $(minikube docker-env)
for svc in patient-service appointment-service audit-service notification-service; do
  (cd services/$svc && docker build -t $svc:local .)
done

# Create namespace
kubectl create namespace dev 2>/dev/null || true

# Deploy all four services
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-dev.yaml \
    --namespace dev
done

# Verify — you should see all releases with STATUS=deployed
helm list -n dev

# Verify pods are running
kubectl get pods -n dev
```

---

## ✅ Checkpoint — answer these before moving on

1. What is the difference between `values.yaml` and `values-dev.yaml`?
2. What does `{{ .Values.replicaCount }}` do when Helm renders the template?
3. What does `{{- if .Values.hpa.enabled }}` do in hpa.yaml?
4. If you run `helm upgrade --install` twice, what happens the second time?
5. Why is `helm rollback` faster than CloudCare v1 rollback?

Next: **[05 — EKS with Terraform](05-eks-terraform.md)** — provision a real
Kubernetes cluster on AWS. This is where free work ends — EKS costs ~$2.40/day.
