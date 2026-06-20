# 08b — HPA Practice: Every File, Every Line

> **Read 08a first.** This doc explains every line of the HPA YAML, resource
> requests/limits in deployments, and how to watch auto-scaling happen live.

---

## 1. Resource requests and limits in deployment.yaml

HPA cannot work without `resources.requests.cpu`. Every service needs this.

In `helm/patient-service/templates/deployment.yaml`:

```yaml
containers:
  - name: patient-service
    image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"

    resources:
      requests:
        cpu: {{ .Values.resources.requests.cpu | quote }}
        # the CPU this pod is GUARANTEED to get
        # HPA uses this as the 100% baseline for CPU percentage calculation
        # the scheduler uses this to decide which node has room for the pod
        memory: {{ .Values.resources.requests.memory | quote }}
        # the memory guaranteed to this pod
        # if a node runs out of memory, pods WITHOUT requests are evicted first

      limits:
        cpu: {{ .Values.resources.limits.cpu | quote }}
        # the MAXIMUM CPU this pod can use
        # if the pod exceeds this, the kernel throttles it (slows it down)
        # does NOT cause a crash — just slower responses

        memory: {{ .Values.resources.limits.memory | quote }}
        # the MAXIMUM memory this pod can use
        # if the pod exceeds this: OOMKilled (Out Of Memory) → pod restarts
        # set higher than requests to allow bursting
```

In `helm/patient-service/values.yaml`:
```yaml
resources:
  requests:
    cpu: "100m"      # 100 millicores = 0.1 vCPU = 10% of one core
    memory: "128Mi"  # 128 mebibytes
  limits:
    cpu: "300m"      # can burst up to 0.3 vCPU
    memory: "256Mi"  # hard cap — exceed this = OOMKilled

# What is 100m (millicores)?
# 1 vCPU = 1000m
# 100m = 10% of one vCPU
# t3.micro has 2 vCPU = 2000m total
# 10 pods × 100m requests = 1000m = 50% of one vCPU → fits on t3.micro
```

In `helm/patient-service/values-prod.yaml`:
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"      # prod: allow higher burst for real traffic
    memory: "256Mi"
```

Do the same `resources` block for all 4 services. Audit and notification
can use smaller values since they do less work per request:

```yaml
# audit-service/values.yaml
resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "200m"
    memory: "128Mi"
```

---

## 2. hpa.yaml — every line explained

`helm/patient-service/templates/hpa.yaml`:

```yaml
{{- if .Values.hpa.enabled }}
# entire file is skipped when hpa.enabled=false (dev)
# rendered only in prod where Metrics Server is running

apiVersion: autoscaling/v2    # v2 supports CPU + memory + custom metrics
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "patient-service.fullname" . }}
  namespace: {{ .Release.Namespace }}

spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "patient-service.fullname" . }}
    # tells HPA: watch and scale THIS Deployment
    # the Deployment name must match exactly

  minReplicas: {{ .Values.hpa.minReplicas }}
  # never scale below this number — even if CPU is 0%
  # set to 2 for patient/appointment (HA: survive node failure)
  # set to 1 for audit/notification (cost saving)

  maxReplicas: {{ .Values.hpa.maxReplicas }}
  # never scale above this number — cost cap
  # also limited by node capacity (t3.micro: ~4-5 pods per node)

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
          # HPA tries to keep average CPU usage across ALL replicas at this %
          # if average goes above → add pods
          # if average goes below → remove pods (after 5-min cooldown)
          #
          # why 60% not 100%?
          # at 100% pods are already slow/unresponsive before scale-up begins
          # 60% gives headroom — pods start before load becomes a problem
          # analogy: a restaurant hires more waiters before the queue gets too long

{{- end }}
```

In `helm/patient-service/values.yaml`:
```yaml
hpa:
  enabled: false                     # off by default
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 60
```

In `helm/patient-service/values-dev.yaml`:
```yaml
hpa:
  enabled: false    # explicitly off in dev (Metrics Server not installed in minikube by default)
```

In `helm/patient-service/values-prod.yaml`:
```yaml
hpa:
  enabled: true     # on in prod — Metrics Server is running (installed via platform/alb.tf)
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 60
```

For audit-service and notification-service (`values-prod.yaml`):
```yaml
hpa:
  enabled: true
  minReplicas: 1    # starts at 1 pod — scale up only when needed
  maxReplicas: 4
  targetCPUUtilizationPercentage: 70    # higher threshold — async services tolerate more load
```

---

## 3. How to watch HPA in action (when EKS is running)

### Check current HPA state:
```bash
kubectl get hpa -n prod

# NAME                  REFERENCE                    TARGETS   MINPODS  MAXPODS  REPLICAS
# patient-service       Deployment/patient-service   12%/60%   2        6        2
#                                                     ↑current  ↑target
# reading: currently at 12% CPU, target 60%, running 2 of min 2 replicas
```

### Watch it continuously:
```bash
kubectl get hpa -n prod -w
# -w = watch, refreshes every few seconds
```

### Trigger a scale-up with a load test:

Install `hey` (HTTP load tester):
```bash
# port-forward patient-service to your laptop
kubectl port-forward svc/patient-service 8001:8001 -n prod &

# install hey
go install github.com/rakyll/hey@latest
# OR: sudo apt install hey

# send 1000 requests, 50 concurrent
hey -n 1000 -c 50 http://localhost:8001/health

# in another terminal, watch HPA:
kubectl get hpa patient-service -n prod -w
```

Expected output as load increases:
```
NAME              TARGETS    REPLICAS
patient-service   12%/60%    2
patient-service   45%/60%    2        ← load increasing
patient-service   78%/60%    2        ← above target → HPA triggers
patient-service   78%/60%    3        ← scaled to 3 pods
patient-service   55%/60%    3        ← load spread across 3 pods, back under target
```

After load stops (wait ~5 minutes for scale-down cooldown):
```
patient-service   15%/60%    3        ← CPU low but HPA waits 5 min
patient-service   12%/60%    3        ← still waiting
patient-service   12%/60%    2        ← scaled back down
```

---

## 4. Troubleshooting HPA

### HPA shows `<unknown>/60%` for TARGETS:
```bash
kubectl describe hpa patient-service -n prod
# look for: "unable to get metrics for resource cpu"
```
Cause: Metrics Server not running or pod missing `resources.requests.cpu`.

Fix:
```bash
# check metrics server is running
kubectl get pods -n kube-system | grep metrics-server

# check pod has resource requests
kubectl describe pod <patient-service-pod-name> -n prod | grep -A5 Requests
```

### HPA not scaling up even at high CPU:
```bash
kubectl describe hpa patient-service -n prod
# look for events at the bottom
```
Common causes:
- Already at `maxReplicas`
- `--horizontal-pod-autoscaler-cpu-initialization-period` not elapsed (new pods need 30s to warm up)
- CPU spike was too brief (HPA averages over multiple samples)

### HPA not scaling down:
Normal — there is a 5-minute cooldown window. This is intentional (see 08a section 6).

---

## ✅ Checkpoint — done when:

- [ ] All 4 Helm charts have `resources.requests.cpu` and `resources.limits.cpu` set
- [ ] All 4 `hpa.yaml` templates have the correct values references
- [ ] `values-prod.yaml` for all 4 services has `hpa.enabled: true`
- [ ] `values-dev.yaml` for all 4 services has `hpa.enabled: false`
- [ ] You can explain: why does HPA need `resources.requests.cpu` to exist?
- [ ] You can explain: why target 60% CPU and not 90%?
- [ ] You can explain: why does scale-down take 5 minutes but scale-up is fast?

Next: **[09a — Observability Concepts](09a-observability-concepts.md)** — understand
what the three-pillar observability stack is and how Prometheus, Grafana, and Loki
each work before installing them.
