# 09 — Prometheus, Grafana, and Loki

> **Goal of this doc:** deploy the three-pillar observability stack — metrics with
> Prometheus, dashboards with Grafana, and log aggregation with Loki — and understand
> what each one shows you about your running services.

---

## 1. The Three Pillars of Observability

Observability means being able to understand what your system is doing *from the
outside*, by looking at the data it emits. The three pillars are:

| Pillar | Tool | Question it answers |
|---|---|---|
| **Metrics** | Prometheus + Grafana | *What is happening?* — request rate, error rate, latency |
| **Logs** | Loki + Promtail | *Why is it happening?* — the actual error messages |
| **Traces** | AWS X-Ray | *Where did it happen?* — which service/function caused slowness |

In CloudCare v1 we used CloudWatch for all three. In v2, we use the cloud-native,
open-source stack (Prometheus/Grafana/Loki) for application observability and keep
CloudWatch for AWS-managed services (RDS, ALB, EKS control plane).

> 🧠 **Why Prometheus and not just CloudWatch?** CloudWatch is excellent for AWS
> resources. But for application-level metrics from your pods — custom request counts,
> business metrics, HTTP latency histograms — Prometheus is the industry standard.
> Every Kubernetes-based company uses it. Knowing Prometheus/Grafana is a transferable
> skill; knowing CloudWatch is AWS-specific.

---

## 2. The RED Method

The most important metrics for any service follow the **RED method**:

- **R**ate — how many requests per second is this service handling?
- **E**rrors — what fraction of requests are returning 5xx errors?
- **D**uration — how long does a typical request take?

For each of your four microservices, you want a Grafana dashboard with these three
graphs. If a service's error rate spikes or duration jumps, that's your signal.

---

## 3. Install the Observability Stack

The entire stack is installed via Helm charts into the `monitoring` namespace.

### 3.1 kube-prometheus-stack (Prometheus + Grafana + AlertManager)

This is one Helm chart that installs everything Prometheus-related:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f monitoring/prometheus/values.yaml
```

`monitoring/prometheus/values.yaml`:
```yaml
grafana:
  enabled: true
  adminPassword: "change-me-in-production"   # use External Secrets in prod
  persistence:
    enabled: true
    size: 5Gi
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: cloudcare
          folder: CloudCare
          type: file
          options:
            path: /var/lib/grafana/dashboards/cloudcare
  dashboardsConfigMaps:
    cloudcare: grafana-cloudcare-dashboards

prometheus:
  prometheusSpec:
    retention: 7d
    retentionSize: "5GB"
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
    # Scrape all pods in all namespaces that have the annotation:
    # prometheus.io/scrape: "true"
    podMonitorNamespaceSelector: {}
    serviceMonitorNamespaceSelector: {}

alertmanager:
  config:
    global:
      slack_api_url: ""   # add your Slack webhook in prod
    route:
      receiver: "null"
      routes:
        - match:
            severity: critical
          receiver: slack
    receivers:
      - name: "null"
      - name: slack
        slack_configs:
          - channel: "#cloudcare-alerts"
            title: "CloudCare Alert"
            text: "{{ .CommonAnnotations.summary }}"
```

### 3.2 Loki Stack (Loki + Promtail)

Loki is a log aggregation system. Promtail is the agent that runs on each node and
ships logs from all pods to Loki.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki-stack \
  grafana/loki-stack \
  --namespace monitoring \
  -f monitoring/loki/values.yaml
```

`monitoring/loki/values.yaml`:
```yaml
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi

promtail:
  enabled: true
  config:
    clients:
      - url: http://loki-stack:3100/loki/api/v1/push
    snippets:
      pipelineStages:
        - docker: {}
        - labeldrop:
            - filename
        - labels:
            app:
            namespace:
            pod:
```

Promtail automatically adds labels to every log line: which pod, which namespace, which
app. This lets you query in Grafana: "show me all logs from `patient-service` in `prod`
in the last 30 minutes."

---

## 4. Exposing Metrics from Your Services

For Prometheus to scrape your services, they need to expose a `/metrics` endpoint.
FastAPI doesn't do this by default — you add the `prometheus_fastapi_instrumentator`
library.

In `requirements.txt`:
```
prometheus_fastapi_instrumentator==6.1.0
```

In `app/main.py`:
```python
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="patient-service")

# Expose /metrics endpoint automatically
Instrumentator().instrument(app).expose(app)
```

After adding this, your service exposes:
```
GET /metrics

# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET", handler="/patients", status="200"} 1523.0
http_requests_total{method="POST", handler="/patients", status="201"} 47.0
http_requests_total{method="GET", handler="/patients", status="404"} 3.0

# HELP http_request_duration_seconds HTTP request duration in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 1200
...
```

Tell Prometheus to scrape this service by adding an annotation to the Helm chart's
Deployment template:

```yaml
# In helm/patient-service/templates/deployment.yaml:
spec:
  template:
    metadata:
      labels:
        ...
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: "/metrics"
        prometheus.io/port: "8001"
```

---

## 5. ServiceMonitor

Alternatively, create a ServiceMonitor resource (the Prometheus-native way):

`helm/patient-service/templates/servicemonitor.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "patient-service.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "patient-service.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

ServiceMonitors are more explicit and don't rely on pod annotations. They're preferred
in production.

---

## 6. Alerting Rules

`monitoring/prometheus/alerts.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cloudcare-alerts
  namespace: monitoring
spec:
  groups:
    - name: cloudcare.services
      rules:

        - alert: HighErrorRate
          expr: |
            (
              rate(http_requests_total{status=~"5.."}[5m])
              / rate(http_requests_total[5m])
            ) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "High error rate on {{ $labels.handler }}"
            description: "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes"

        - alert: PodCrashLooping
          expr: |
            rate(kube_pod_container_status_restarts_total[5m]) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.pod }} in {{ $labels.namespace }} is crash-looping"

        - alert: HPAMaxReplicas
          expr: |
            kube_horizontalpodautoscaler_status_current_replicas
            == kube_horizontalpodautoscaler_spec_max_replicas
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "HPA {{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }} at max"

        - alert: RDSStorageLow
          expr: aws_rds_free_storage_space_average < 2147483648   # 2 GB
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "RDS free storage below 2 GB"

        - alert: HighRequestLatency
          expr: |
            histogram_quantile(0.95,
              rate(http_request_duration_seconds_bucket[5m])
            ) > 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "P95 latency on {{ $labels.handler }} is {{ $value }}s"
```

Apply:
```bash
kubectl apply -f monitoring/prometheus/alerts.yaml
```

---

## 7. Accessing Grafana

```bash
# Port-forward Grafana to your localhost
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

# Open in browser: http://localhost:3000
# Username: admin
# Password: the value you set in values.yaml
```

### Key Dashboards to Build

**Dashboard 1: Service Overview (one panel per service)**

PromQL queries to use:

```promql
# Request rate (requests/second over last 5 minutes)
rate(http_requests_total{namespace="prod"}[5m])

# Error rate (% of 5xx responses)
sum(rate(http_requests_total{status=~"5..", namespace="prod"}[5m]))
  /
sum(rate(http_requests_total{namespace="prod"}[5m]))
  * 100

# P99 latency (99th percentile response time)
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m]))
  by (le, handler)
)
```

**Dashboard 2: Kubernetes Cluster Overview**

The `kube-prometheus-stack` chart automatically installs the official Kubernetes
Grafana dashboards. Look for:
- "Kubernetes / Compute Resources / Namespace (Pods)" — CPU and memory per pod
- "Kubernetes / Networking" — bytes in/out per pod
- "HPA" — current vs desired replicas

**Dashboard 3: Log Exploration**

In Grafana, go to **Explore → Select Loki datasource**.

LogQL query to see all logs from patient-service in the last 30 minutes:
```logql
{namespace="prod", app="patient-service"}
```

Filter to just errors:
```logql
{namespace="prod"} |= "ERROR"
```

See logs from all services together:
```logql
{namespace="prod"} | json | level="ERROR"
```

---

## 8. Structured Logging (Important for Loki)

For Loki to be useful, your services should emit **structured JSON logs** instead of
plain text. Add this to your FastAPI services:

```python
import logging
import json

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "ts": self.formatTime(record),
            "level": record.levelname,
            "service": "patient-service",
            "message": record.getMessage(),
            "module": record.module,
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.root.handlers = [handler]
logging.root.setLevel(logging.INFO)
```

Now every log line is valid JSON:
```json
{"ts": "2026-07-01T09:15:22Z", "level": "INFO", "service": "patient-service", "message": "GET /patients 200 OK in 12ms", "module": "main"}
{"ts": "2026-07-01T09:15:25Z", "level": "ERROR", "service": "patient-service", "message": "Database connection timeout", "module": "database"}
```

This makes Loki queries vastly more powerful — you can filter by any JSON field.

---

## 9. CloudWatch for AWS-Layer Metrics

Even with Prometheus/Grafana, keep CloudWatch for AWS-managed resources:
- **RDS** — CPU, connections, free storage (CloudWatch has native RDS metrics)
- **ALB** — request count, 5xx rate, target health
- **EKS control plane** — API server latency, etcd size

Configure the CloudWatch datasource in Grafana to pull these into the same dashboard
where you see your application metrics. This gives you a single pane of glass.

---

## ✅ Checkpoint

You should be able to:

- [ ] Run `helm install kube-prometheus-stack` and access Grafana at `localhost:3000`
- [ ] Add `/metrics` to a FastAPI service and see it scraped by Prometheus
- [ ] Build a Grafana panel showing request rate using PromQL
- [ ] Query logs from `patient-service` using Loki and LogQL
- [ ] Explain the difference between metrics, logs, and traces
- [ ] Explain why Prometheus/Grafana is used alongside CloudWatch

Next: **[10 — Multi-Environment with Kustomize](10-multi-env.md)** — manage dev and
prod differences cleanly using Kustomize overlays on top of your Helm charts.
