# 09a — Observability: Concepts and Mental Model

> **Goal:** understand what observability means, why the three-pillar stack
> (Prometheus + Grafana + Loki) exists, and how each tool fits into your running
> cluster. Read this fully before going to 09b.

---

## 1. The Problem Without Observability

Right now your services are running on EKS. A user reports "the appointment service
is slow." Without observability, your only option is:

```
1. SSH into a node (you can't — managed nodes)
2. Read pod logs manually — kubectl logs <pod> — one pod at a time
3. Guess which service is the problem
4. Restart everything and hope
```

With observability:

```
1. Open Grafana — see appointment-service P99 latency jumped from 50ms to 2s at 09:15
2. Check Prometheus — see CPU at 95% at that time (HPA hadn't fired yet)
3. Open Loki — see "database connection timeout" in logs at 09:14
4. Root cause: RDS connection pool exhausted — fix it in 10 minutes
```

Observability means being able to understand what your system is doing from the
*outside*, using the data it emits — without touching the running system.

---

## 2. The Three Pillars

| Pillar | Tool | What it stores | Question it answers |
|---|---|---|---|
| **Metrics** | Prometheus + Grafana | Numbers over time | *What is happening right now and historically?* |
| **Logs** | Loki + Promtail | Text lines from pods | *Why is it happening?* |
| **Traces** | AWS X-Ray (future) | Request paths across services | *Where exactly did the slowness occur?* |

In CloudCare v1 we used **CloudWatch** for all three. In v2, we use the open-source
stack for application-level observability and keep CloudWatch for AWS-managed resources
(RDS, ALB, EKS control plane). Reason: Prometheus/Grafana/Loki is the industry standard
for Kubernetes — every company you'll work at uses it, not CloudWatch.

---

## 3. Prometheus — How It Works

### The scrape model

Prometheus does **not** receive data. Your services do not push metrics to Prometheus.
Prometheus **pulls** — it visits each service's `/metrics` endpoint every 15 seconds
and records the numbers it finds.

```
Every 15 seconds:
Prometheus → GET /metrics → patient-service
Prometheus → GET /metrics → appointment-service
Prometheus → GET /metrics → audit-service
Prometheus → GET /metrics → notification-service
Prometheus → GET /metrics → each node (node-exporter)
Prometheus → GET /metrics → Kubernetes API (kube-state-metrics)
```

This is called **scraping**. Prometheus stores every value with a timestamp in its
own time-series database.

### What a /metrics endpoint looks like

```
# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET", handler="/patients", status="200"} 1523.0
http_requests_total{method="POST", handler="/patients", status="201"} 47.0
http_requests_total{method="GET", handler="/patients", status="404"} 3.0

# HELP http_request_duration_seconds HTTP request duration in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 1200
http_request_duration_seconds_bucket{le="0.01"} 1350
http_request_duration_seconds_bucket{le="0.025"} 1490
http_request_duration_seconds_bucket{le="+Inf"} 1523
```

Each line is a metric name + labels (the `{}` part) + a value. Prometheus stores
all of these every 15 seconds — that is your time-series data.

### The four metric types

| Type | What it counts | Example |
|---|---|---|
| **Counter** | Only goes up, never resets | `http_requests_total` — total requests since pod started |
| **Gauge** | Goes up and down | `memory_usage_bytes` — current memory right now |
| **Histogram** | Counts values in buckets | `http_request_duration_seconds` — how many requests under 5ms, under 10ms, etc. |
| **Summary** | Pre-calculated percentiles | Like histogram but client-side calculation |

Counter is the most common. You use `rate()` in PromQL to convert a counter into
requests-per-second.

---

## 4. PromQL — The Query Language

You use PromQL to ask questions of Prometheus. Grafana runs PromQL queries and draws
the results as graphs. Three queries you will use constantly:

### Request rate (requests per second)
```promql
rate(http_requests_total{namespace="prod"}[5m])
```
`rate()` calculates how fast a counter is increasing over a time window (`[5m]` = last 5 minutes).
Result: requests per second per service.

### Error rate (% of 5xx responses)
```promql
sum(rate(http_requests_total{status=~"5..", namespace="prod"}[5m]))
/
sum(rate(http_requests_total{namespace="prod"}[5m]))
* 100
```
`status=~"5.."` means "status matches regex 5xx". Divide error requests by total requests.
Result: percentage of requests that are errors.

### P99 latency (99th percentile response time)
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m]))
  by (le, handler)
)
```
`histogram_quantile(0.99, ...)` calculates the 99th percentile from the histogram buckets.
Result: the response time that 99% of requests are faster than.

---

## 5. The RED Method

For every microservice, you want exactly three graphs. This is called the **RED method**:

- **R**ate — how many requests/second is this service handling?
- **E**rrors — what fraction of requests are returning 5xx errors?
- **D**uration — how long does a typical request (P99) take?

If a service's error rate is non-zero or its duration jumps — that is your signal.
Everything else in Grafana is secondary.

---

## 6. Grafana — How It Works

Grafana does not store any data. It is purely a **visualization layer**.

```
Prometheus (stores metrics data)
    ↑
    │  PromQL query
    │
Grafana (draws graphs from query results)
    ↑
    │  you look at dashboards
    │
Your browser
```

When you open a Grafana dashboard, Grafana runs the PromQL queries you configured
against Prometheus and draws the results as graphs. Grafana also connects to Loki
(for logs) and CloudWatch (for AWS metrics) — these are called **datasources**.

### Key Grafana concepts

| Concept | What it is |
|---|---|
| **Datasource** | A backend Grafana queries: Prometheus, Loki, CloudWatch |
| **Dashboard** | A page with multiple panels |
| **Panel** | One graph, table, or stat — backed by one PromQL/LogQL query |
| **Explore** | Ad-hoc query tool — good for debugging without a pre-built dashboard |
| **AlertManager** | Handles alert routing — sends to Slack, PagerDuty, email |

---

## 7. Loki — How It Works

Loki is **not** Elasticsearch. It does not index the content of your log messages.
It only indexes the **labels** attached to each log line (pod name, namespace, app name).
This makes it much cheaper to run.

### How logs flow into Loki

```
Pod writes log to stdout
    ↓
Docker/containerd captures it (every pod's stdout is stored on the node as a file)
    ↓
Promtail (runs as a DaemonSet — one pod per node) reads those files
    ↓
Promtail attaches labels: {namespace="prod", app="patient-service", pod="patient-service-xyz"}
    ↓
Promtail pushes to Loki
    ↓
Loki stores with the labels
    ↓
Grafana queries Loki with LogQL
```

**DaemonSet** means one Promtail pod runs on every node automatically. No matter how
many nodes you have, each node gets a Promtail pod that ships its pod logs to Loki.

### LogQL basics

```logql
# All logs from patient-service in prod
{namespace="prod", app="patient-service"}

# Filter to lines containing "ERROR"
{namespace="prod"} |= "ERROR"

# Parse JSON logs and filter by level field
{namespace="prod"} | json | level="ERROR"

# Count error rate over time
rate({namespace="prod"} |= "ERROR" [5m])
```

LogQL starts with a label selector `{...}` (like a filter) then optionally pipes
into further filtering or parsing.

---

## 8. How the Stack Fits Inside Your Cluster

```
Your VPC — public subnets (worker nodes)
┌─────────────────────────────────────────────────────┐
│                                                     │
│  Node 1                        Node 2               │
│  ┌──────────────────┐          ┌──────────────────┐ │
│  │ patient-service  │          │ appointment-svc  │ │
│  │ audit-service    │          │ notification-svc │ │
│  │ prometheus pod   │          │ grafana pod      │ │
│  │ promtail pod     │          │ promtail pod     │ │
│  └──────────────────┘          └──────────────────┘ │
│                                                     │
│  kube-system namespace:                             │
│  metrics-server, loki, alertmanager                 │
└─────────────────────────────────────────────────────┘
```

All monitoring components run as pods inside your cluster — in the `monitoring`
namespace. They are installed via Helm charts, just like your application services.
Prometheus and Grafana are not separate servers — they are pods.

---

## 9. Prometheus vs CloudWatch — Which to Use When

| Scenario | Use |
|---|---|
| Application metrics (request rate, latency, error rate) | Prometheus + Grafana |
| Pod logs | Loki |
| RDS CPU, connections, free storage | CloudWatch (native RDS metrics) |
| ALB request count, 5xx rate, target health | CloudWatch (native ALB metrics) |
| EKS control plane API server latency | CloudWatch (EKS publishes to CW) |
| Custom business metrics (e.g. "appointments booked per hour") | Prometheus |

CloudWatch is excellent for AWS-managed services because AWS publishes those metrics
automatically. Prometheus is better for application-level metrics because it is
Kubernetes-native and your pods can expose any custom metric you want.

In Grafana you configure **both** as datasources — one unified dashboard can show
application P99 latency from Prometheus alongside RDS CPU from CloudWatch.

---

## 10. AlertManager — How Alerts Work

AlertManager is installed as part of the `kube-prometheus-stack`. It handles routing
of firing alerts to notification channels (Slack, PagerDuty, email).

```
Prometheus evaluates alert rules every 15s
    │  rule fires (e.g. error rate > 5% for 5 minutes)
    ▼
AlertManager receives the alert
    │  matches alert against routing rules
    ▼
Sends to Slack / PagerDuty / email
```

Alert rules are written in PromQL:
```yaml
- alert: HighErrorRate
  expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.05
  for: 5m          # must be true for 5 minutes before firing — avoids false alarms
  labels:
    severity: critical
```

The `for: 5m` is important — a 2-second spike won't page you. The condition must
hold for the full duration before AlertManager sends the notification.

---

## 11. Structured Logging (Why It Matters for Loki)

If your pods log like this:
```
2026-07-01 09:15:22 ERROR Database connection timeout after 30s
```

Loki can only filter by `|= "ERROR"` — a text match. You can't filter by specific
fields.

If your pods log JSON:
```json
{"ts": "2026-07-01T09:15:22Z", "level": "ERROR", "service": "patient-service", "message": "Database connection timeout", "duration_ms": 30000}
```

Then in LogQL you can do:
```logql
{namespace="prod"} | json | level="ERROR" | duration_ms > 5000
```

Structured logs make Loki dramatically more useful. This is why 09b adds a JSON
formatter to each FastAPI service.

---

**You understand the observability stack. Go to
[09b — Observability Practice](09b-observability-practice.md)
to install Prometheus, Grafana, and Loki and see your services' metrics live.**
