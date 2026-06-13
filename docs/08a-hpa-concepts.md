# 08a — HPA: Concepts and Mental Model

> **Goal:** understand how Kubernetes automatically scales pods up and down
> based on real traffic load — and why static replica counts are a problem.
> Read this fully before going to 08b.

---

## 1. The problem without HPA

Right now your Helm charts set a fixed number of replicas:

```yaml
# values-prod.yaml
replicaCount: 2
```

This means patient-service always runs 2 pods. Always. Even at 3am when
traffic is near zero. Even during a spike when 100 users hit it at once.

```
3am:   2 pods running, 5% CPU used     → you're paying for idle capacity
9am:   2 pods running, 90% CPU used    → users experience slow responses
10am:  2 pods running, 100% CPU → pods crash → requests fail → downtime
```

Static replicas = either wasteful or dangerous, never both right.

---

## 2. What HPA does

HPA (Horizontal Pod Autoscaler) watches your pods' CPU usage and automatically
adjusts the number of replicas.

```
Low traffic  → scale DOWN to minimum replicas  → save cost
High traffic → scale UP to maximum replicas    → handle load
```

"Horizontal" means adding more pods (not making each pod bigger).
"Vertical" scaling = making each pod use more CPU/memory (different tool: VPA).

```
Without HPA:
  traffic: ──────▄▄▄▄▄▄████████▄▄▄▄──────
  pods:     ──────────────2────────────────   (fixed, always 2)

With HPA:
  traffic: ──────▄▄▄▄▄▄████████▄▄▄▄──────
  pods:     ────────2──2─4──6──4──2──2─────   (follows traffic)
```

---

## 3. How HPA works — the 4 components

```
┌─────────────────┐     reads CPU      ┌──────────────────┐
│  Metrics Server  │ ◄─────────────── │   kubelet (node)  │
│  (in kube-system)│                   │   measures pods   │
└────────┬────────┘                    └──────────────────┘
         │ serves metrics
         ▼
┌─────────────────┐     adjusts        ┌──────────────────┐
│  HPA Controller  │ ──────────────► │   Deployment      │
│  (built into K8s)│  replicas field  │   (your service)  │
└─────────────────┘                   └──────────────────┘
```

1. **kubelet** — runs on every node, measures CPU usage of every pod every 15s
2. **Metrics Server** — aggregates those measurements, serves them as an API
   (installed by `helm_release.metrics_server` in platform/alb.tf)
3. **HPA Controller** — built into Kubernetes, checks metrics every 15s,
   calculates desired replicas, updates the Deployment
4. **Deployment** — reacts to replica count change, creates/removes pods

---

## 4. The HPA math — how it decides replica count

HPA uses this formula:

```
desired replicas = ceil(current replicas × (current CPU% / target CPU%))
```

Example: patient-service has 2 pods running at 80% CPU, target is 50%:

```
desired = ceil(2 × (80 / 50))
        = ceil(2 × 1.6)
        = ceil(3.2)
        = 4 pods
```

HPA scales up to 4. As traffic drops, CPU drops. If pods are at 20% CPU:

```
desired = ceil(4 × (20 / 50))
        = ceil(4 × 0.4)
        = ceil(1.6)
        = 2 pods
```

HPA scales back down to 2.

---

## 5. Why resource requests are required

HPA calculates CPU% **relative to the pod's resource request**.

```yaml
resources:
  requests:
    cpu: "100m"    # this pod is "promised" 100 millicores
```

If the pod uses 80m CPU:
```
CPU% = 80m / 100m = 80%
```

Without `resources.requests.cpu`, HPA has no baseline to calculate a percentage
→ HPA cannot work → stays at the fixed replica count.

Resource requests also serve another purpose: the Kubernetes scheduler uses
them to decide which node has room for the pod.

```
requests: what the pod is guaranteed to get
limits:   the maximum the pod can use (gets throttled if it exceeds this)
```

---

## 6. Scale-up vs scale-down speed

HPA has built-in safety: it scales **up fast** but scales **down slow**.

```
Scale up:
  HPA can double the replica count every 15 seconds.
  Reason: traffic spikes are sudden — respond fast or users suffer.

Scale down:
  HPA waits 5 minutes of sustained low CPU before scaling down.
  Reason: traffic often drops temporarily then spikes again.
  Scaling down and immediately scaling back up wastes time and causes
  unnecessary pod restarts (cold-start latency, connection draining).
```

```
CPU spike at 9:00:   2 pods → 4 pods (within 30 seconds)
Traffic drops 9:05:  CPU at 20% — HPA waits 5 minutes
Traffic stays low:   9:10 → 4 pods → 2 pods
```

You can tune these cooldown periods in newer Kubernetes versions with
`scaleDown.stabilizationWindowSeconds`.

---

## 7. HPA limits in this project

```
Service              minReplicas  maxReplicas  target CPU
──────────────────── ──────────── ──────────── ──────────
patient-service      2            6            60%
appointment-service  2            6            60%
audit-service        1            4            70%
notification-service 1            4            70%
```

Why different limits?
- patient and appointment: synchronous, user-facing → need faster scaling, higher HA floor
- audit and notification: async, fire-and-forget → can tolerate higher CPU before scaling
- minReplicas=2 for user-facing: ensures one pod survives if a node fails (HA)
- minReplicas=1 for async: saves cost — async services can queue briefly

---

## 8. HPA vs node scaling

HPA scales **pods** within existing nodes. But what if all nodes are full?

```
Node 1:  [pod][pod][pod][pod]  ← 4 pods, node is full (t3.micro)
Node 2:  [pod][pod][pod][pod]  ← 4 pods, node is full

HPA wants to add a 9th pod → no node has space → pod stays "Pending"
```

The solution is **Cluster Autoscaler** — it adds new EC2 nodes when pods can't
be scheduled. We set `max_size = 4` in the node group, so up to 4 nodes
can be added automatically. This is not implemented in this project but is
the natural next step after HPA.

For this project: 2 nodes × t3.micro can run ~8-10 small pods total.
With our replica counts (2+2+1+1 = 6 minimum, 6+6+4+4 = 20 maximum),
the nodes may fill up at peak — acceptable for a learning project.

---

## 9. HPA in dev vs prod

```
Dev (minikube):
  HPA is disabled (hpa.enabled: false in values-dev.yaml)
  Reason: minikube has limited CPU — HPA would constantly try to scale
          when your laptop is running other apps, creating confusing behavior

Prod (EKS):
  HPA is enabled (hpa.enabled: true in values-prod.yaml)
  Metrics Server is running (installed via platform/alb.tf)
  Real traffic, real scaling
```

---

**You understand HPA. Go to [08b — HPA Practice](08b-hpa-practice.md)
to read every line of the HPA YAML and learn how to test auto-scaling.**
