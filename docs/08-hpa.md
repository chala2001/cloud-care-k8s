# 08 — Horizontal Pod Autoscaling (HPA)

> **Goal of this doc:** understand how Kubernetes automatically scales pods up under
> load and back down when idle, replacing the slower instance-refresh mechanism from
> CloudCare v1.

---

## 1. HPA vs ASG Auto Scaling

In CloudCare v1, scaling was handled by the EC2 Auto Scaling Group. When CPU was high,
AWS launched a new EC2 instance — which took **5–10 minutes** to boot, pull the image,
start the app, and pass health checks.

In CloudCare-K8s, scaling is handled by the **Horizontal Pod Autoscaler (HPA)**. When
CPU is high, Kubernetes adds a new **pod** — which takes **20–40 seconds** to start.

```
v1: High CPU → ASG launches new EC2 → 5–10 min → traffic spreads
v2: High CPU → HPA adds new pod    → 30 sec    → traffic spreads
```

**Why is a pod so much faster than an EC2 instance?**
- No OS boot — the container OS is already running on the node
- The Docker image is usually cached on the node
- The app starts in the same process context — no systemd, no init, no userdata

---

## 2. How HPA Works

HPA is a Kubernetes controller that:
1. Reads metrics from the **Metrics Server** (CPU, memory)
2. Calculates the desired number of replicas: `ceil(current_replicas × current_utilization / target_utilization)`
3. Updates the Deployment's `spec.replicas` field

```
HPA (watches every 15 seconds)
  ← reads CPU utilization from Metrics Server
  → decides: desired replicas = ceil(2 × 85% / 70%) = ceil(2.43) = 3
  → updates Deployment.spec.replicas = 3
  → Deployment creates a new pod
```

The Metrics Server must be installed in the cluster. On minikube:
```bash
minikube addons enable metrics-server
```

On EKS, it's deployed as part of the platform stack:
```hcl
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
}
```

---

## 3. The HPA Manifest

`helm/patient-service/templates/hpa.yaml` (the complete version):
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
    name: {{ .Release.Name }}   # must match the Deployment name

  minReplicas: {{ .Values.hpa.minReplicas }}   # never scale below this
  maxReplicas: {{ .Values.hpa.maxReplicas }}   # never scale above this

  metrics:
    # Scale based on CPU utilization
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # Scale up when average CPU across all pods exceeds this %
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60    # wait 60s before scaling up again
      policies:
        - type: Pods
          value: 2                      # add at most 2 pods per scale event
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5 min before scaling down
      policies:
        - type: Pods
          value: 1                      # remove at most 1 pod per scale event
          periodSeconds: 60
{{- end }}
```

**Understanding the `behavior` block:**

- **`scaleUp.stabilizationWindowSeconds: 60`** — after HPA decides to scale up, it
  won't scale up again for 60 seconds. Prevents "thrashing" — many small scale events
  instead of one big one.
- **`scaleDown.stabilizationWindowSeconds: 300`** — after load drops, HPA waits 5 minutes
  before removing pods. This prevents removing pods during a brief lull only to add them
  back 2 minutes later. Conservative by design.
- **`scaleDown.policies: value: 1`** — removes one pod at a time, slowly. Aggressive
  scale-down can cause request failures if the remaining pods can't absorb the traffic
  fast enough.

> 🧠 **Scale up fast, scale down slow** is the golden rule. Traffic spikes are sudden;
> traffic decreases are gradual. You want to add capacity immediately when needed but
> reduce it cautiously to avoid dropping requests.

---

## 4. Values for Dev vs Prod

In `values-dev.yaml` (HPA disabled — save resources on minikube):
```yaml
hpa:
  enabled: false
```

In `values-prod.yaml`:
```yaml
hpa:
  enabled: true
  minReplicas: 2      # always at least 2 for high availability
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
```

Why `minReplicas: 2` in prod?
- If a node fails, pods are moved to the surviving node automatically.
- With `minReplicas: 1`, a node failure means **zero** patient-service pods until the
  pod is rescheduled. With 2, one pod keeps running immediately.

---

## 5. Deploying and Testing HPA on minikube

### Enable Metrics Server

```bash
minikube addons enable metrics-server

# Wait ~60 seconds then verify it's running
kubectl get pods -n kube-system | grep metrics-server
# metrics-server-6d94bc8694-xk9pq   1/1   Running   0   2m
```

### Deploy with HPA Enabled

```yaml
# values-test.yaml — HPA enabled for testing
hpa:
  enabled: true
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 50   # low threshold to trigger scaling easily
```

```bash
helm upgrade --install patient-service ./helm/patient-service \
  -f values-test.yaml \
  --namespace dev
```

### Check Current HPA State

```bash
kubectl get hpa -n dev
# NAME              REFERENCE                        TARGETS   MINPODS   MAXPODS   REPLICAS
# patient-service   Deployment/patient-service       3%/50%    1         4         1
```

The `TARGETS` column shows `current/target`. Right now CPU is 3%, target is 50%.
One replica is enough.

### Simulate Load

```bash
# Port-forward patient-service
kubectl port-forward svc/patient-service 8001:8001 -n dev &

# In a separate terminal, generate load with a simple loop
while true; do
  curl -s http://localhost:8001/patients > /dev/null
done
```

Watch HPA react:
```bash
# In another terminal
watch kubectl get hpa -n dev
# After 1-2 minutes the CPU % rises above 50%
# HPA adds replicas: REPLICAS goes from 1 → 2 → 3

kubectl get pods -n dev
# NAME                               READY   STATUS    RESTARTS   AGE
# patient-service-7d9f8b6c9-xk2pq   1/1     Running   0          5m    ← original
# patient-service-7d9f8b6c9-mnp3q   1/1     Running   0          90s   ← HPA added
# patient-service-7d9f8b6c9-rst7p   1/1     Running   0          30s   ← HPA added
```

Stop the load and watch scale-down after 5 minutes:
```bash
# Kill the loop (Ctrl+C in the load-generating terminal)
# Wait ~5 minutes
watch kubectl get hpa -n dev
# Replicas slowly drops back to 1
```

---

## 6. What HPA Cannot Do Alone

HPA scales pods. But pods run on nodes (EC2 instances). What if you have so many pods
that they can't all fit on your two `t3.micro` nodes?

In that case, the pods go `Pending` — waiting for a node with enough resources.

**Cluster Autoscaler** solves this by adding new EC2 nodes when pods are pending. This
project doesn't configure Cluster Autoscaler (it would add ~$2/day in extra EC2 costs),
but it's worth knowing the concept:

```
HPA: "I need 8 patient-service pods"
  → 6 pods scheduled, 2 pods Pending (no node has space)
Cluster Autoscaler: "2 pods are pending, add a new node"
  → New t3.micro node launches
  → 2 pending pods get scheduled
```

For a learning project on free tier, `maxReplicas: 6` keeps us within the two-node
capacity.

---

## 7. Alerting on HPA Saturation

In Doc 09, we set up Prometheus. One of the alerts to configure:

```yaml
- alert: HPAMaxReplicas
  expr: |
    kube_horizontalpodautoscaler_status_current_replicas
    == kube_horizontalpodautoscaler_spec_max_replicas
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "HPA {{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }} at max replicas"
    description: "HPA has been at max replicas for 10+ minutes. Consider increasing maxReplicas or the node group."
```

If this alert fires, it means pods can't scale any further — load is increasing but
you've hit the ceiling. This is the signal to either increase `maxReplicas` or add more
worker nodes.

---

## ✅ Checkpoint

You should be able to explain:

- What is the difference between HPA and ASG auto scaling?
- Why is pod scale-out ~30 seconds vs ~5 minutes for EC2?
- What is the Metrics Server and why is it required for HPA?
- What does `scaleDown.stabilizationWindowSeconds: 300` do?
- Why is `minReplicas: 2` important for high availability?
- What is the Cluster Autoscaler and when would you need it?

Next: **[09 — Prometheus, Grafana, and Loki](09-observability.md)** — set up the
three-pillar observability stack: metrics, dashboards, and log aggregation.
