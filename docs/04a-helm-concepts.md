# 04a — Helm: Concepts and Mental Model

> **Goal:** understand WHY Helm exists, what every Helm term means, and how
> templates + values work together. Read this fully before going to 04b.

---

## 1. The problem without Helm

You now have raw YAML files in `k8s/base/`. They work for dev. But you also need
to deploy to prod. The differences between dev and prod for patient-service:

| Setting | Dev | Prod |
|---|---|---|
| `replicas` | 1 | 2 |
| `image.tag` | `local` | `a3f8b2c` (git SHA) |
| `image.pullPolicy` | `Never` | `Always` |
| `resources.requests.memory` | `64Mi` | `128Mi` |
| `LOG_LEVEL` | `DEBUG` | `WARNING` |
| HPA | disabled | enabled |
| Secrets | plain K8s Secret | AWS Secrets Manager |

Without Helm, you need **two full copies** of every YAML file — one for dev, one
for prod. For 4 services × 3 YAML files each = **24 YAML files to maintain**.

Change one thing (e.g. the image tag on every deploy) → edit multiple files.
Easy to forget one. Files drift out of sync. Human error.

---

## 2. What Helm does

Helm lets you write **one set of YAML templates** with `{{ placeholder }}` blanks,
then fill those blanks differently per environment using **values files**.

```
                         ┌─── values-dev.yaml ───┐
                         │  replicaCount: 1       │
template/deployment.yaml │  image.tag: local      │       dev YAML
  replicas: {{ .Values.replicaCount }}   +  │  pullPolicy: Never    │  ──────►  (1 replica,
  image: ...:{{ .Values.image.tag }}        └───────────────────────┘           local image)


                         ┌─── values-prod.yaml ──┐
template/deployment.yaml │  replicaCount: 2      │       prod YAML
  replicas: {{ .Values.replicaCount }}   +  │  image.tag: a3f8b2c  │  ──────►  (2 replicas,
  image: ...:{{ .Values.image.tag }}        │  pullPolicy: Always   │           ECR image)
                         └───────────────────────┘
```

> Think of it like a **fill-in-the-blank exam paper**. The paper (template) is
> printed once. Each student (environment) fills in their own answers (values).
> Same paper, different answers, different result.

---

## 3. The 4 Helm words you must know

### Chart
A **chart** is a folder containing your templates + values files.
One chart = one microservice.

```
helm/patient-service/     ← this entire folder is one chart
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-prod.yaml
└── templates/
    └── deployment.yaml ...
```

### Values
**Values** are the variables that fill in the template blanks.
They come from `values.yaml` (defaults) + your environment file (overrides).

```
values.yaml says:      replicaCount: 1
values-prod.yaml says: replicaCount: 2

When deploying to prod, Helm reads BOTH files.
values-prod.yaml wins → replicaCount becomes 2.
```

Only list what CHANGES in the environment file. Everything else is inherited from
`values.yaml`. This keeps the environment files small.

### Release
A **release** is one deployed instance of a chart.

```
helm upgrade --install patient-service ./helm/patient-service -n dev
                        ↑ release name  ↑ chart path           ↑ namespace

→ creates release "patient-service" in namespace "dev"
```

You can have the same chart deployed twice as different releases:
```
Release "patient-service" in namespace dev   ← one release
Release "patient-service" in namespace prod  ← different release, same chart
```

They are completely independent. Updating one does not affect the other.

### Render
**Rendering** is when Helm fills in the blanks and produces final plain YAML.

```
templates/deployment.yaml   }
values-dev.yaml             }  → Helm renders → final deployment YAML → sent to Kubernetes
Chart.yaml                  }
```

You can see the rendered output without applying anything:
```bash
helm template patient-service ./helm/patient-service -f values-dev.yaml
```
This is useful to verify values are correct before deploying.

---

## 4. How values merging works

Helm always reads `values.yaml` first (the defaults). Then merges the environment
file on top. The environment file values win.

```
values.yaml:          values-dev.yaml:         Final result:
─────────────         ────────────────         ─────────────
replicaCount: 1       (not listed)             replicaCount: 1  ← from values.yaml
image:                image:
  tag: "latest"         tag: "local"           image.tag: local ← dev file wins
  pullPolicy:           pullPolicy: Never       image.pullPolicy: Never ← dev file wins
    IfNotPresent
LOG_LEVEL: "INFO"     LOG_LEVEL: "DEBUG"       LOG_LEVEL: DEBUG ← dev file wins
hpa:                  hpa:
  enabled: false        (not listed)           hpa.enabled: false ← from values.yaml
```

**You only write what changes** in the environment file. The rest comes from defaults.

---

## 5. Go template syntax — 5 things to understand

Helm uses Go's template language. You will see these in the template files:

### Reading a value
```
{{ .Values.replicaCount }}
```
`.Values` = the merged values (from values.yaml + your environment file)
`.replicaCount` = the key you want

Result: `1` (in dev) or `2` (in prod)

### Reading release info
```
{{ .Release.Name }}       → "patient-service" (what you typed in helm upgrade --install)
{{ .Release.Namespace }}  → "dev" or "prod"
{{ .Chart.AppVersion }}   → "1.0.0" (from Chart.yaml)
```

### Conditional block
```
{{- if .Values.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
...
{{- end }}
```
If `hpa.enabled` is `false` → this entire block produces NO output at all.
In dev: HPA YAML is not applied. In prod: HPA YAML is applied.
One template handles both cases.

### Loop
```
{{- range $key, $val := .Values.env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
```
This loops over every key-value pair in the `env:` map and creates one env var entry
per pair. You add env vars by adding to values.yaml — no template change needed.

### The `-` in `{{-`
The `-` strips blank lines from the output.
```
{{- if .Values.hpa.enabled }}   ← strip blank line BEFORE this line
{{- end }}                       ← strip blank line BEFORE this line
```
Without `-`, the rendered YAML would have empty lines everywhere and might be invalid.

---

## 6. What each file in the chart does

```
helm/patient-service/
│
├── Chart.yaml          WHO AM I
│                       Name, version, description of this chart.
│                       Helm refuses to install without this file.
│
├── values.yaml         SAFE DEFAULTS
│                       Every variable used in templates is defined here.
│                       If a variable is missing from values-dev or values-prod,
│                       this value is used as the fallback.
│
├── values-dev.yaml     DEV OVERRIDES
│                       Only the values that differ in dev.
│                       Small file — only differences, not everything.
│
├── values-prod.yaml    PROD OVERRIDES
│                       Only the values that differ in prod.
│
└── templates/
    ├── _helpers.tpl    REUSABLE SNIPPETS
    │                   Defines label blocks used by all templates.
    │                   Name starts with _ so Helm knows not to apply it directly.
    │
    ├── deployment.yaml THE MAIN WORKLOAD
    │                   Creates the Deployment that runs your pods.
    │
    ├── service.yaml    THE DNS NAME
    │                   Creates the Service that gives pods a stable address.
    │
    ├── hpa.yaml        AUTO-SCALING RULE
    │                   Only rendered when hpa.enabled=true.
    │                   Skipped entirely in dev.
    │
    └── externalsecret.yaml   PROD SECRET SYNC
                        Only rendered when externalSecret.enabled=true.
                        Tells External Secrets Operator to pull from AWS Secrets Manager.
                        Skipped in dev. Covered fully in Doc 07.
```

---

## 7. The dev vs prod difference visualised

```
Dev deployment (values-dev.yaml):

    Deployment
    ├── replicas: 1
    ├── image: patient-service:local
    ├── imagePullPolicy: Never
    ├── env: LOG_LEVEL=DEBUG
    ├── DATABASE_URL: plain value from Secret
    └── No HPA created


Prod deployment (values-prod.yaml):

    Deployment
    ├── replicas: 2
    ├── image: 123456.ecr.amazonaws.com/...:a3f8b2c
    ├── imagePullPolicy: Always
    ├── env: LOG_LEVEL=WARNING
    ├── DATABASE_URL: read from K8s Secret (which ESO pulled from AWS Secrets Manager)
    └── HPA created (scales 2→6 pods based on CPU)
```

Same chart. Two very different results.

---

## 8. Why Helm rollback is powerful

Every `helm upgrade` creates a new **revision** number. Helm stores the history.

```
Deploy v1:  helm upgrade --install ...   → revision 1 (running)
Deploy v2:  helm upgrade --install ...   → revision 2 (running)  ← bad deploy!

Roll back:  helm rollback patient-service 1 -n dev
            → revision 3 is created (but uses revision 1's config)
            → takes ~30 seconds
```

Compare to CloudCare v1 rollback:
- Find the old AMI ID
- Re-tag it as latest
- Push to ECR
- Trigger instance refresh
- Wait 5–10 minutes for new EC2 instances to boot

Helm rollback: **one command, 30 seconds**.

---

## 9. The Helm workflow

```
1. Write templates once (done — in helm/ folder)
        │
2. Write values files per environment (done)
        │
3. helm template ... (preview rendered YAML — always do this first)
        │
4. helm upgrade --install ... (apply to cluster)
        │
5. kubectl get pods (verify pods are running)
        │
6. If something is wrong: helm rollback ... (one command, instant)
```

---

**You now understand Helm fully. Go to [04b — Helm Practice](04b-helm-practice.md)
to read every line of every chart file and deploy to minikube.**
