# 09b — Observability Practice: Every File, Every Line

> **Read 09a first.** This doc installs Prometheus, Grafana, and Loki into your EKS
> cluster, adds `/metrics` to your FastAPI services, and wires up alerting. Every
> config line is explained.

---

## 1. Directory Structure for Monitoring Files

Create these files before running any Helm commands:

```
cloud-care-k8s/
└── monitoring/
    ├── prometheus/
    │   ├── values.yaml        ← Prometheus + Grafana + AlertManager config
    │   └── alerts.yaml        ← PrometheusRule: alert conditions
    └── loki/
        └── values.yaml        ← Loki + Promtail config
```

---

## 2. Install kube-prometheus-stack (Prometheus + Grafana + AlertManager)

This one Helm chart installs all three components together.

```bash
# Add the Prometheus community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install into a dedicated monitoring namespace
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 58.3.1 \
  -f monitoring/prometheus/values.yaml
```

`--create-namespace` creates the `monitoring` namespace if it does not exist.
`--version 58.3.1` pins the chart version — always pin in production to avoid
surprise upgrades.

---

## 3. monitoring/prometheus/values.yaml — every line

```yaml
# ── Grafana ────────────────────────────────────────────────────────────────────
grafana:
  enabled: true

  adminPassword: "change-me-in-production"
  # hardcoded password is fine for local/dev learning
  # in production: store in Secrets Manager, inject via ExternalSecret

  persistence:
    enabled: true
    size: 5Gi
    # Grafana stores dashboards and datasource configs on disk
    # without persistence, your dashboards are lost every time the pod restarts
    # 5Gi is more than enough (dashboards are tiny JSON files)

  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: cloudcare
          folder: CloudCare
          # all dashboards loaded from this provider appear in a "CloudCare" folder in Grafana
          type: file
          options:
            path: /var/lib/grafana/dashboards/cloudcare
            # Grafana watches this directory — any JSON file placed here becomes a dashboard

  dashboardsConfigMaps:
    cloudcare: grafana-cloudcare-dashboards
    # tells Grafana to mount a ConfigMap named "grafana-cloudcare-dashboards"
    # into the dashboard directory above
    # you create dashboard JSON files as a ConfigMap — Grafana auto-loads them

# ── Prometheus ─────────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    retention: 7d
    # keep 7 days of metrics history
    # older data is automatically deleted
    # increase to 30d if you want longer history (requires more disk)

    retentionSize: "5GB"
    # also delete old data if disk usage exceeds 5GB
    # both retention and retentionSize are enforced — whichever triggers first

    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          # ReadWriteOnce = one pod can write at a time
          # correct for Prometheus — it is a single-instance pod
          resources:
            requests:
              storage: 10Gi
              # Prometheus time-series database grows over time
              # 10Gi holds ~7 days of metrics for 4 microservices comfortably

    podMonitorNamespaceSelector: {}
    serviceMonitorNamespaceSelector: {}
    # {} means "all namespaces"
    # Prometheus will discover ServiceMonitors and PodMonitors in ANY namespace
    # without this, Prometheus only watches its own namespace (monitoring)
    # and misses your prod/dev namespace services

# ── AlertManager ───────────────────────────────────────────────────────────────
alertmanager:
  config:
    global:
      slack_api_url: ""
      # paste your Slack webhook URL here when you set up a Slack workspace
      # format: https://hooks.slack.com/services/T.../B.../...

    route:
      receiver: "null"
      # default: send nothing (catches alerts with no specific route)
      routes:
        - match:
            severity: critical
          receiver: slack
          # any alert with severity=critical label → send to slack receiver

    receivers:
      - name: "null"
        # the null receiver silently discards alerts — used as the default catch-all
      - name: slack
        slack_configs:
          - channel: "#cloudcare-alerts"
            title: "CloudCare Alert: {{ .CommonLabels.alertname }}"
            text: "{{ .CommonAnnotations.summary }}"
            # .CommonLabels and .CommonAnnotations come from the PrometheusRule
            # you define what text appears in the Slack message
```

---

## 4. Install Loki Stack (Loki + Promtail)

```bash
# Add the Grafana Helm repo (Loki is maintained by Grafana Labs)
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki-stack \
  grafana/loki-stack \
  --namespace monitoring \
  --version 2.10.2 \
  -f monitoring/loki/values.yaml
```

---

## 5. monitoring/loki/values.yaml — every line

```yaml
# ── Loki (the log storage + query engine) ─────────────────────────────────────
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
    # Loki stores compressed log chunks on disk
    # 10Gi holds several weeks of logs for 4 small services
    # logs compress well — JSON logs compress to ~10% of original size

# ── Promtail (the log shipper — runs on every node) ───────────────────────────
promtail:
  enabled: true
  # Promtail is deployed as a DaemonSet automatically
  # Kubernetes ensures one Promtail pod runs on every worker node
  # no matter how many nodes you add (via HPA node scaling), each gets a Promtail

  config:
    clients:
      - url: http://loki-stack:3100/loki/api/v1/push
        # where Promtail ships logs to
        # "loki-stack" is the Kubernetes Service name created by the Helm chart
        # port 3100 is Loki's default HTTP port
        # this is cluster-internal DNS — works without any public URL

    snippets:
      pipelineStages:
        - docker: {}
          # parse the Docker log format (adds timestamp, stream, log fields)
          # every container log is wrapped in Docker's JSON format on disk

        - labeldrop:
            - filename
            # removes the "filename" label (the raw file path on the node)
            # keeping it would create too many label combinations (cardinality explosion)
            # Loki performance degrades badly with too many unique label values

        - labels:
            app:
            namespace:
            pod:
            # promote these fields to Loki labels
            # these come from Kubernetes pod metadata that Promtail auto-discovers
            # result: every log line is tagged with which app, namespace, and pod it came from
            # this is what makes {namespace="prod", app="patient-service"} queries work
```

---

## 6. Add /metrics to Your FastAPI Services

FastAPI does not expose a `/metrics` endpoint by default. Add the
`prometheus_fastapi_instrumentator` library.

### 6.1 requirements.txt (do this for ALL 4 services)

```
# existing dependencies ...
prometheus_fastapi_instrumentator==6.1.0
```

### 6.2 app/main.py — patient-service (and repeat for all 4 services)

```python
from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="patient-service")

# Register all routes first, then expose /metrics
# The instrumentator hooks into FastAPI's middleware to measure every request
Instrumentator().instrument(app).expose(app)
# instrument(app) → starts recording http_requests_total and http_request_duration_seconds
# expose(app)     → adds GET /metrics route that Prometheus will scrape
```

After this change, your service exposes:
```bash
curl http://localhost:8001/metrics
# returns the Prometheus text format shown in 09a section 3
```

---

## 7. Tell Prometheus to Scrape Your Services

You have two options. Use Option A (annotations) — it is simpler.

### Option A — Pod annotations in the Helm deployment template

In `helm/patient-service/templates/deployment.yaml`, add annotations to the pod
template (not the Deployment metadata — the pod template metadata):

```yaml
spec:
  template:
    metadata:
      labels:
        {{- include "patient-service.selectorLabels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"
        # tells Prometheus: visit this pod's /metrics endpoint
        # without this annotation, Prometheus ignores the pod

        prometheus.io/path: "/metrics"
        # the path to scrape — /metrics is the default but being explicit avoids
        # confusion if you ever change it

        prometheus.io/port: "8001"
        # which port to scrape
        # must match the containerPort in the same deployment.yaml
        # patient-service uses 8001 (see values.yaml)
```

Do the same for all 4 services with their correct ports:

| Service | Port |
|---|---|
| patient-service | 8001 |
| appointment-service | 8002 |
| audit-service | 8003 |
| notification-service | 8004 |

### Option B — ServiceMonitor (more explicit, preferred in production)

Create `helm/patient-service/templates/servicemonitor.yaml`:

```yaml
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
# ServiceMonitor is a custom resource installed by kube-prometheus-stack
# it tells Prometheus which Kubernetes Services to scrape

metadata:
  name: {{ include "patient-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}

spec:
  selector:
    matchLabels:
      {{- include "patient-service.selectorLabels" . | nindent 6 }}
      # Prometheus finds the Service whose labels match this selector
      # must match the labels on your Service resource (service.yaml)

  endpoints:
    - port: http
      # "http" is the name of the port in your service.yaml
      # name must match, not the port number
      path: /metrics
      interval: 15s
      # how often Prometheus visits /metrics — 15s is the standard
{{- end }}
```

In `values.yaml`:
```yaml
serviceMonitor:
  enabled: false    # off by default, enable in prod
```

In `values-prod.yaml`:
```yaml
serviceMonitor:
  enabled: true
```

---

## 8. monitoring/prometheus/alerts.yaml — every line

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
# PrometheusRule is a custom resource installed by kube-prometheus-stack
# Prometheus watches for PrometheusRule resources and loads the rules automatically

metadata:
  name: cloudcare-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    # this label is REQUIRED — without it, Prometheus ignores this rule
    # kube-prometheus-stack only picks up PrometheusRules with this label

spec:
  groups:
    - name: cloudcare.services
      rules:

        - alert: HighErrorRate
          expr: |
            (
              rate(http_requests_total{status=~"5.."}[5m])
              /
              rate(http_requests_total[5m])
            ) > 0.05
          # fires when more than 5% of requests in the last 5 minutes are 5xx errors
          for: 5m
          # must stay above 5% for a full 5 minutes before AlertManager fires
          # prevents false alarms from brief spikes
          labels:
            severity: critical
          annotations:
            summary: "High error rate on {{ $labels.handler }}"
            # $labels.handler = the route that is failing, e.g. /patients
            description: "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes"

        - alert: PodCrashLooping
          expr: |
            rate(kube_pod_container_status_restarts_total[5m]) > 0
          # kube_pod_container_status_restarts_total is published by kube-state-metrics
          # which is installed automatically by kube-prometheus-stack
          # fires if any container has restarted at all in the last 5 minutes
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.pod }} in {{ $labels.namespace }} is crash-looping"

        - alert: HPAAtMaxReplicas
          expr: |
            kube_horizontalpodautoscaler_status_current_replicas
            == kube_horizontalpodautoscaler_spec_max_replicas
          # fires when HPA has scaled to maxReplicas and cannot scale further
          # means your service is at capacity — traffic may already be degraded
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "HPA {{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }} at max replicas"

        - alert: HighRequestLatency
          expr: |
            histogram_quantile(0.95,
              rate(http_request_duration_seconds_bucket[5m])
            ) > 2
          # P95 latency exceeds 2 seconds
          # 95th percentile: 95% of users are seeing this latency or better
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "P95 latency on {{ $labels.handler }} is {{ $value }}s (threshold: 2s)"

        - alert: RDSStorageLow
          expr: aws_rds_free_storage_space_average < 2147483648
          # 2147483648 bytes = 2 GB
          # aws_rds_free_storage_space_average comes from the CloudWatch datasource
          # requires the CloudWatch datasource configured in Grafana
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "RDS free storage below 2 GB — consider expanding"
```

Apply the alert rules:
```bash
kubectl apply -f monitoring/prometheus/alerts.yaml
```

Verify Prometheus loaded them:
```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# open http://localhost:9090/alerts in browser
# you should see your 5 rules listed
```

---

## 9. Add Structured JSON Logging to FastAPI Services

Add this to each service's `app/main.py`. Do it for all 4 services.

```python
import logging
import json

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "ts": self.formatTime(record),
            "level": record.levelname,
            "service": "patient-service",
            # change this string for each service
            "message": record.getMessage(),
            "module": record.module,
        })
        # every log line is now valid JSON on a single line
        # Promtail ships this to Loki
        # Loki indexes: namespace, app, pod (from K8s metadata)
        # LogQL can then filter: | json | level="ERROR" | service="patient-service"

handler = logging.StreamHandler()
# StreamHandler writes to stdout — this is the correct place for container logs
# Kubernetes/Docker captures stdout and writes it to the node's log files
# Promtail reads those files

handler.setFormatter(JSONFormatter())
logging.root.handlers = [handler]
logging.root.setLevel(logging.INFO)
```

After this change, logs look like:
```json
{"ts": "2026-07-01T09:15:22Z", "level": "INFO", "service": "patient-service", "message": "GET /patients 200 OK in 12ms", "module": "main"}
{"ts": "2026-07-01T09:15:25Z", "level": "ERROR", "service": "patient-service", "message": "Database connection timeout", "module": "database"}
```

---

## 10. Access Grafana

```bash
# port-forward Grafana to your laptop
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

# open in browser: http://localhost:3000
# username: admin
# password: the value from values.yaml (change-me-in-production)
```

### Add Loki as a datasource in Grafana

1. Go to **Configuration → Data Sources → Add data source**
2. Select **Loki**
3. URL: `http://loki-stack:3100`
   (cluster-internal DNS — works because Grafana pod is inside the same cluster)
4. Click **Save & Test** — should say "Data source connected"

### Key pre-built dashboards (from kube-prometheus-stack)

The chart installs these automatically — find them under **Dashboards → Browse**:

| Dashboard name | What it shows |
|---|---|
| Kubernetes / Compute Resources / Namespace (Pods) | CPU and memory per pod |
| Kubernetes / Networking | Bytes in/out per pod |
| Kubernetes / HPA | Current vs desired replicas per HPA |
| Node Exporter / Nodes | Per-node CPU, memory, disk, network |

---

## 11. Build Your Own RED Dashboard

In Grafana: **Dashboards → New → New Dashboard → Add visualization**

Select **Prometheus** as datasource. Add 3 panels for patient-service:

**Panel 1 — Request Rate**
```promql
rate(http_requests_total{namespace="prod", app="patient-service"}[5m])
```
Visualization: **Time series** graph. Title: "Request Rate (req/s)"

**Panel 2 — Error Rate**
```promql
sum(rate(http_requests_total{status=~"5..", namespace="prod", app="patient-service"}[5m]))
/
sum(rate(http_requests_total{namespace="prod", app="patient-service"}[5m]))
* 100
```
Visualization: **Time series** graph. Title: "Error Rate (%)"
Add a threshold line at 5 (red above 5%).

**Panel 3 — P99 Latency**
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{namespace="prod", app="patient-service"}[5m]))
  by (le)
)
```
Visualization: **Time series** graph. Title: "P99 Latency (seconds)"
Add a threshold line at 2 (red above 2s).

Repeat these 3 panels for each of the 4 services. Save the dashboard as
"CloudCare — Service Overview".

---

## 12. Explore Logs with Loki

In Grafana: **Explore → Select Loki datasource**

```logql
# All logs from patient-service in prod
{namespace="prod", app="patient-service"}

# Only error lines
{namespace="prod", app="patient-service"} |= "ERROR"

# Structured JSON — filter by level field
{namespace="prod"} | json | level="ERROR"

# See logs from ALL services with errors at once
{namespace="prod"} | json | level="ERROR"

# Count how many errors per minute (good for graphing)
rate({namespace="prod"} | json | level="ERROR" [1m])
```

---

## 13. Verify Everything Is Working

```bash
# 1. Check all monitoring pods are Running
kubectl get pods -n monitoring
# Expected: prometheus, grafana, alertmanager, loki, promtail (x2 for 2 nodes) all Running

# 2. Check Prometheus is scraping your services
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# open http://localhost:9090/targets
# you should see patient-service, appointment-service, etc. listed as UP

# 3. Check Prometheus has your alert rules loaded
# open http://localhost:9090/alerts
# you should see HighErrorRate, PodCrashLooping, etc.

# 4. Check Promtail is shipping logs
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20
# look for: "successfully sent batch to loki"

# 5. Test an alert fires
# artificially trigger a crash-loop by breaking a service temporarily
kubectl set image deployment/patient-service patient-service=bad-image:latest -n prod
# watch the pod fail, then check Grafana Alerting → Alert Rules
# after 5m, check AlertManager received it:
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring
# open http://localhost:9093 — you should see the firing alert
# restore: helm upgrade --install patient-service helm/patient-service -n prod -f helm/patient-service/values-prod.yaml
```

---

## 14. Troubleshooting

### Prometheus shows service as DOWN in /targets
```bash
# Check the pod has the annotation
kubectl describe pod <pod-name> -n prod | grep prometheus
# should see: prometheus.io/scrape: "true"

# Check the port matches
kubectl get svc patient-service -n prod
# compare the port to prometheus.io/port annotation
```

### No data in Grafana panels
```bash
# Check Prometheus has data
# In Grafana Explore → Prometheus → run a simple query:
# http_requests_total
# if you see no results, Prometheus is not scraping
```

### Loki shows no logs
```bash
# Check Promtail is running on both nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
# should be 2 pods (one per node), both Running

# Check Promtail config
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail | grep -i error
```

### Alert rules not visible in Prometheus /alerts
```bash
# Check the label — this is the most common cause
kubectl describe prometheusrule cloudcare-alerts -n monitoring
# must have: release: kube-prometheus-stack label
```

---

## ✅ Checkpoint — done when:

- [ ] All monitoring pods are `Running` in the `monitoring` namespace
- [ ] `http://localhost:9090/targets` shows your 4 services as `UP`
- [ ] `http://localhost:9090/alerts` shows your 5 alert rules
- [ ] Grafana at `localhost:3000` shows the Kubernetes pre-built dashboards
- [ ] You built a RED dashboard for patient-service (rate, errors, P99 latency)
- [ ] Loki query `{namespace="prod"}` returns logs in Grafana Explore
- [ ] You can explain: why does Prometheus scrape instead of services pushing metrics?
- [ ] You can explain: why does Loki not index log content (only labels)?
- [ ] You can explain: what is a DaemonSet and why is Promtail deployed as one?

Next: **[10a — Multi-Environment Concepts](10a-multi-env-concepts.md)** — understand
namespace isolation, Helm multi-release, and Kustomize base/overlay patterns before
building the dev and prod environments.
