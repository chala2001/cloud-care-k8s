# 03a — Kubernetes: Concepts and Mental Model

> **Goal of this doc:** before touching any YAML, fully understand what Kubernetes
> is, what each building block does, and how they connect. Read this completely
> before going to 03b.

---

## 1. What is Kubernetes?

You have 4 microservices. Each runs in a Docker container. You need them to:
- Always stay running (restart if they crash)
- Scale up when traffic is high, scale down when quiet
- Update to a new version without downtime
- Find and talk to each other by name

You could do this manually — SSH into servers, restart crashed containers, load balance manually. But that's hundreds of hours of work and human error.

**Kubernetes does all of this automatically.**

It is a system that manages containers across one or more servers, making sure your apps are always running, healthy, and able to talk to each other.

> Think of Kubernetes as a **very smart building manager** for your applications.
> You tell it what you want ("3 copies of patient-service always running").
> It figures out how to make that happen and keeps it that way forever.

---

## 2. The Cluster — the building

Everything in Kubernetes runs inside a **cluster**. A cluster is one or more servers
(called **nodes**) managed by Kubernetes together.

```
┌─────────────────── Kubernetes Cluster ───────────────────────┐
│                                                               │
│   Node 1 (EC2 t3.micro)        Node 2 (EC2 t3.micro)        │
│   ┌───────────────────┐        ┌───────────────────┐         │
│   │  patient-service  │        │ appointment-svc   │         │
│   │  audit-service    │        │ notification-svc  │         │
│   └───────────────────┘        └───────────────────┘         │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

On minikube, the entire cluster is one virtual machine on your laptop.
On AWS EKS (Doc 05), nodes are real EC2 instances.

---

## 3. Pod — the smallest unit

A **Pod** is the smallest thing Kubernetes manages. It wraps one or more containers
that run together and share the same network.

```
Pod
└── Container (your Docker image running)
    ├── Gets an IP address
    ├── Has environment variables
    └── Has resource limits (CPU, memory)
```

**Key things to understand about pods:**

**Pods are temporary.** When a pod crashes, Kubernetes deletes it and creates a
brand new one. The new pod gets a new IP address and a new name. You can never rely
on a pod's IP address or name staying the same.

**You almost never create pods directly.** You create a Deployment, and the
Deployment creates pods for you.

```
You create:      Deployment
                     ↓ creates and manages
Kubernetes runs: Pod → Pod → Pod  (as many as you specified)
```

---

## 4. Deployment — the pod manager

A **Deployment** is your instruction to Kubernetes:
> "I want 2 copies of patient-service always running. If one crashes, replace it.
> If I push a new version, update them one at a time without downtime."

```
Deployment: "always keep 2 patient-service pods running"

  Normal state:    Pod A ✓   Pod B ✓
  Pod A crashes:   Pod A ✗   Pod B ✓  → Kubernetes creates Pod C immediately
  After recovery:            Pod B ✓   Pod C ✓
```

**Rolling update** — when you deploy a new version:
```
Step 1:  Pod A (old) ✓   Pod B (old) ✓
Step 2:  Pod A (old) ✓   Pod B (old) ✓   Pod C (new) starting...
Step 3:  Pod A (old) ✓   Pod C (new) ✓   ← Pod B replaced once Pod C is healthy
Step 4:  Pod D (new) ✓   Pod C (new) ✓   ← Pod A replaced once Pod D is healthy
```
At every step, at least one pod is serving traffic. Zero downtime.

**This is the biggest difference from CloudCare v1.**
- v1: update = SSH in, pull new image, restart → brief downtime
- v2: update = Deployment rolling update → zero downtime

---

## 5. Service — the stable address

Remember: pods die and are replaced. Their IP addresses change every time.

If appointment-service tries to call patient-service using its IP `10.244.0.5`,
and then that pod crashes and gets replaced with IP `10.244.0.8`, the call fails.

A **Service** solves this. It gives your pods a **stable DNS name and IP** that never
changes, even as the pods behind it come and go.

```
                         Service: patient-service
                         ClusterIP: 10.96.45.12 (stable, never changes)
                         DNS name: patient-service (stable, never changes)
                              │
                    ┌─────────┴──────────┐
                    ▼                    ▼
              Pod A: 10.244.0.5    Pod B: 10.244.0.8
              (may die tomorrow)   (may die tomorrow)
```

When appointment-service calls `http://patient-service:8001`:
1. Kubernetes DNS resolves `patient-service` to the Service's ClusterIP
2. The Service routes to one of the healthy pods behind it (load balancing)
3. The pod handles the request

The calling service never needs to know which pod it's talking to.

**Three types of Service:**

| Type | Reachable from | Used for |
|---|---|---|
| ClusterIP | Inside the cluster only | Internal services (audit, notification) |
| NodePort | Outside via node's IP + port | Simple testing |
| LoadBalancer | Public internet via cloud load balancer | Production (via Ingress) |

All our services use **ClusterIP** — internal only. The Ingress (Doc 05) is what
exposes patient-service and appointment-service to the public internet.

---

## 6. Namespace — virtual floors in the building

A cluster can be shared by multiple teams or environments. **Namespaces** are virtual
partitions that isolate resources from each other.

```
Cluster
├── namespace: dev         ← development environment
│   ├── patient-service pod
│   ├── appointment-service pod
│   └── postgres pod
├── namespace: prod        ← production environment
│   ├── patient-service pod (different image, 2 replicas)
│   ├── appointment-service pod
│   └── (RDS in AWS, not a pod)
└── namespace: monitoring  ← Prometheus, Grafana, Loki
    └── prometheus pod
```

Resources in different namespaces are isolated. A Service named `patient-service`
in `dev` is NOT the same as `patient-service` in `prod`. They don't interfere.

**Short DNS names only work within the same namespace:**
```
# From a pod in dev namespace:
http://patient-service:8001          ✓  reaches dev patient-service
http://patient-service.prod:8001     ✓  reaches prod patient-service (full name)
```

---

## 7. ConfigMap — the shared notice board

You need to pass configuration to your pods: what database schema to use, what
log level to set, what URL to call for other services.

You could hardcode these in the Dockerfile. But then every environment change needs
a new Docker build. That's slow and wrong.

A **ConfigMap** stores non-secret configuration as key-value pairs inside the cluster.
Pods read from it at startup as environment variables.

```
ConfigMap: patient-service-config
  DB_SCHEMA: "patients"
  LOG_LEVEL:  "INFO"
        ↓
  patient-service pod reads these as environment variables
```

> Think of ConfigMap as a **notice board inside the building**. You pin config
> values there. When a pod starts, it reads the notice board.

In Helm (Doc 04), this is handled automatically via the `env:` section in values.yaml.
The Deployment template converts those values into pod environment variables.

---

## 8. Secret — the locked drawer

Passwords, API keys, and database URLs must not be stored in plain ConfigMaps because
anyone with cluster access could read them.

A **Secret** stores sensitive data encoded in base64. Pods consume them as environment
variables.

```
Secret: patient-service-db-secret
  DATABASE_URL: cG9zdGdyZXNxbDovLy4uLg==   ← base64 encoded
                    ↓ decoded when pod reads it
  DATABASE_URL: postgresql://patient_svc:patient_pass@postgres:5432/cloudcare
```

> **Important:** base64 is NOT encryption. Anyone with kubectl access can decode it.
> For real security, we use the **External Secrets Operator** in Doc 07, which pulls
> secrets from AWS Secrets Manager where they are actually encrypted.

For dev/minikube, plain Secrets are fine. For prod, ESO (Doc 07) takes over.

---

## 9. How all the pieces connect

```
┌─────────────── namespace: dev ──────────────────────────────────────┐
│                                                                      │
│  ConfigMap          Secret                                           │
│  ┌──────────┐       ┌──────────────┐                                │
│  │DB_SCHEMA │       │DATABASE_URL  │                                │
│  │LOG_LEVEL │       │(encrypted)   │                                │
│  └────┬─────┘       └──────┬───────┘                                │
│       │ env vars           │ env vars                               │
│       ▼                    ▼                                        │
│  ┌─────────────────────────────┐                                    │
│  │         Deployment          │  "keep 1 pod running always"       │
│  │  ┌────────────────────────┐ │                                    │
│  │  │     Pod (container)    │ │                                    │
│  │  │   patient-service:local│ │                                    │
│  │  └────────────────────────┘ │                                    │
│  └─────────────────────────────┘                                    │
│                 ↑ routes traffic to                                  │
│  ┌──────────────────────────┐                                       │
│  │  Service: patient-service │  DNS: patient-service:8001           │
│  │  ClusterIP (stable IP)    │  other pods use this name            │
│  └──────────────────────────┘                                       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**The flow when appointment-service calls patient-service:**

```
appointment-service pod
  calls: http://patient-service:8001/patients/1
                │
                ▼
  Kubernetes DNS resolves "patient-service" → 10.96.45.12 (Service ClusterIP)
                │
                ▼
  Service routes to a healthy patient-service pod
                │
                ▼
  Pod handles request, returns response
```

---

## 10. What kubectl apply does

When you run `kubectl apply -f patient-service.yaml`:

```
Step 1: kubectl reads the YAML file on your laptop
Step 2: Sends it to the Kubernetes API server inside the cluster
Step 3: Kubernetes stores what you want (the "desired state")
Step 4: Kubernetes compares desired state vs current state
Step 5: Makes changes to reach desired state

e.g. "desired: 1 patient-service pod, current: 0 pods"
  → Kubernetes pulls the Docker image and starts a pod
```

**Kubernetes constantly watches and reconciles.** If a pod crashes:
```
desired state: 1 pod running
current state: 0 pods running  ← mismatch!
  → Kubernetes creates a new pod immediately
```

This self-healing loop runs every few seconds, forever.

---

## 11. readinessProbe vs livenessProbe

Every Deployment should define two health checks:

**readinessProbe** — "is this pod ready to receive traffic?"
```
Pod starts → Kubernetes waits → hits GET /health
  200 OK    → pod is added to Service rotation (traffic flows in)
  not 200   → pod stays out of rotation (users don't hit it yet)
```

During a rolling update, new pods only get traffic after readiness passes. This
is how zero-downtime deployments work — old pods keep serving until new pods are ready.

**livenessProbe** — "is this pod still alive and working?"
```
Pod running → Kubernetes periodically hits GET /health
  200 OK    → pod is healthy, nothing changes
  not 200   → pod is stuck/deadlocked → Kubernetes kills and replaces it
```

Without these probes:
- No readinessProbe → users hit pods that haven't finished starting → errors
- No livenessProbe → a frozen/deadlocked pod stays in rotation forever

---

## 12. Summary — the 7 building blocks

| Resource | What it is | Analogy |
|---|---|---|
| Pod | A running container | One employee at their desk |
| Deployment | Manages pods, keeps count, rolling updates | HR manager |
| Service | Stable DNS name for a set of pods | Company phone extension |
| Namespace | Virtual partition inside cluster | A floor in the building |
| ConfigMap | Non-secret config key-value pairs | Notice board |
| Secret | Sensitive data (base64) | Locked drawer |
| Ingress | Routes external traffic to services | Reception desk |

---

**You now understand the concepts. Go to [03b — Kubernetes Practice](03b-k8s-practice.md)
to write every YAML file with each line explained.**
