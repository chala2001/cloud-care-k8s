# 03 — Kubernetes Manifests

> **Goal of this doc:** understand the core Kubernetes building blocks — Pod, Deployment,
> Service, Ingress, Namespace, ConfigMap, and Secret — and write real YAML manifests for
> the CloudCare microservices. By the end, you'll deploy all four services to minikube
> and verify they can talk to each other.

All work in this doc runs on **minikube — zero cost.**

---

## 1. The Core Concepts

Before writing YAML, understand what each resource *is*.

### Pod

A Pod is the smallest deployable unit in Kubernetes. It wraps one or more containers
that share a network and storage. In practice, most pods run exactly one container.

```
Pod
└── Container(s)
    ├── Docker image
    ├── Environment variables
    ├── Volume mounts
    └── Resource limits
```

**You almost never create pods directly.** You create a Deployment, which creates pods
for you and keeps them healthy.

### Deployment

A Deployment manages a set of identical pods. It:
- ensures the desired number of replicas (`replicas: 2` = always 2 pods running)
- replaces a crashed pod automatically
- performs rolling updates without downtime
- lets you roll back to a previous version

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 2           # always keep 2 pods running
  selector: ...
  template: ...         # pod template — what each pod looks like
```

> 🧠 **Why not just run a container with docker run?** If it crashes, nobody restarts it.
> If you want to update it, you have downtime. A Deployment solves both problems.

### Service

Pods get random IP addresses and die and are replaced. You can't hardcode a pod's IP.
A **Service** provides a stable DNS name and IP address that always routes to healthy
pods matching its selector.

```
patient-service (Service)
  ├── clusterIP: 10.96.45.12  (stable, virtual)
  └── selector: app=patient-service
        ├── pod: patient-service-7d9f-abc1 (10.244.0.5)
        └── pod: patient-service-7d9f-def2 (10.244.0.6)
```

When appointment-service calls `http://patient-service:8001`, Kubernetes DNS resolves
`patient-service` to the Service's stable IP, which load-balances across healthy pods.

Three types of Services used in this project:
- **ClusterIP** (default): reachable only within the cluster. For internal services.
- **NodePort**: exposes on a port on every node. Used for local testing.
- **LoadBalancer**: creates an AWS ALB. Used in production via the Ingress controller.

### Ingress

An Ingress is an API object that defines how external HTTP traffic enters the cluster.
It's like a routing table: "requests to `/api/patients` → patient-service on port 8001".

An **Ingress Controller** is the actual pod that processes Ingress rules. We use the
**AWS ALB Ingress Controller**, which creates an AWS Application Load Balancer for each
Ingress resource.

```
Internet
  → ALB (created by Ingress Controller)
    → /api/patients/*  → patient-service:8001
    → /api/appointments/* → appointment-service:8002
```

### Namespace

Namespaces are virtual partitions inside a cluster. We use:
- `dev` — development environment
- `prod` — production environment
- `monitoring` — Prometheus, Grafana, Loki

Resources in different namespaces are isolated. A Service in `dev` is not reachable
from `prod` by its short name.

### ConfigMap

A ConfigMap holds non-secret configuration data as key-value pairs. Pods consume it
as environment variables or mounted files.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: patient-service-config
data:
  DB_SCHEMA: "patients"
  LOG_LEVEL: "INFO"
```

### Secret

A Secret holds sensitive data (passwords, tokens) encoded in base64. Pods consume it
as environment variables (preferred) or mounted files.

> 🧠 **Base64 is NOT encryption.** A Kubernetes Secret is just base64-encoded, which
> anyone with cluster access can decode. In production (Doc 07), we use the
> **External Secrets Operator** to pull real secrets from AWS Secrets Manager. For
> now, we use basic Kubernetes Secrets so you understand the concept.

---

## 2. The Namespace Manifests

`k8s/base/namespaces.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
  labels:
    environment: dev
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    environment: prod
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
```

Apply:
```bash
kubectl apply -f k8s/base/namespaces.yaml
kubectl get namespaces
# NAME          STATUS   AGE
# default       Active   5d
# dev           Active   2s
# monitoring    Active   2s
# prod          Active   2s
```

---

## 3. patient-service Manifests

`k8s/base/patient-service.yaml`:
```yaml
# --- Deployment ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: patient-service
  namespace: dev
  labels:
    app: patient-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: patient-service        # must match template labels
  template:
    metadata:
      labels:
        app: patient-service      # pods get this label
    spec:
      containers:
        - name: patient-service
          image: patient-service:local    # minikube local image
          imagePullPolicy: Never
          ports:
            - containerPort: 8001
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: patient-service-db-secret
                  key: DATABASE_URL
            - name: DB_SCHEMA
              value: "patients"
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8001
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8001
            initialDelaySeconds: 15
            periodSeconds: 20
---
# --- Service ---
apiVersion: v1
kind: Service
metadata:
  name: patient-service
  namespace: dev
spec:
  selector:
    app: patient-service           # routes to pods with this label
  ports:
    - protocol: TCP
      port: 8001                   # port on the Service (what callers use)
      targetPort: 8001             # port on the pod
  type: ClusterIP                  # internal only
---
# --- Secret (local dev only — see Doc 07 for production) ---
apiVersion: v1
kind: Secret
metadata:
  name: patient-service-db-secret
  namespace: dev
type: Opaque
stringData:                        # stringData auto-encodes to base64
  DATABASE_URL: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
```

Let's break down the key parts:

**`selector.matchLabels` and `template.metadata.labels` must match.** The Deployment uses
the selector to find *which pods it manages*. If they don't match, the Deployment
creates pods it can never find.

**`resources.requests` and `resources.limits`:**
- `requests` — the minimum resources guaranteed to the pod. Kubernetes uses this for
  scheduling (finding a node with enough capacity).
- `limits` — the maximum the pod can use. Kubernetes kills pods that exceed memory limits.

**`readinessProbe`** — Kubernetes waits for this to pass before sending traffic to the pod.
During a rolling update, new pods only get traffic after their readiness probe succeeds —
this is how zero-downtime deploys work.

**`livenessProbe`** — Kubernetes restarts a pod that fails this check. It detects
deadlocked or crashed applications.

> 🧠 **Always define both probes in production.** Without `readinessProbe`, traffic
> hits pods that haven't finished starting. Without `livenessProbe`, a hung pod
> stays in the rotation forever.

---

## 4. appointment-service Manifests

`k8s/base/appointment-service.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: appointment-service
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: appointment-service
  template:
    metadata:
      labels:
        app: appointment-service
    spec:
      containers:
        - name: appointment-service
          image: appointment-service:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8002
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: appointment-service-db-secret
                  key: DATABASE_URL
            - name: DB_SCHEMA
              value: "appointments"
            - name: PATIENT_SERVICE_URL
              value: "http://patient-service:8001"   # cluster DNS
            - name: AUDIT_SERVICE_URL
              value: "http://audit-service:8003"
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8002
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: appointment-service
  namespace: dev
spec:
  selector:
    app: appointment-service
  ports:
    - port: 8002
      targetPort: 8002
  type: ClusterIP
---
apiVersion: v1
kind: Secret
metadata:
  name: appointment-service-db-secret
  namespace: dev
type: Opaque
stringData:
  DATABASE_URL: "postgresql://appt_svc:appt_pass@postgres:5432/cloudcare"
```

---

## 5. audit-service and notification-service Manifests

These follow the same pattern but are **internal only** (ClusterIP, no Ingress rule).

`k8s/base/audit-service.yaml` (key parts):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audit-service
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: audit-service
  template:
    metadata:
      labels:
        app: audit-service
    spec:
      containers:
        - name: audit-service
          image: audit-service:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8003
          env:
            - name: DYNAMODB_TABLE
              value: "audit_events"
            - name: AWS_DEFAULT_REGION
              value: "ap-south-1"
            - name: DYNAMODB_ENDPOINT_URL
              value: "http://dynamodb-local:8000"   # local dev only
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
```

---

## 6. The Ingress Manifest

An Ingress routes external traffic to the right service based on path.

`k8s/base/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: dev
  annotations:
    # Tell the AWS ALB Ingress Controller to create an internet-facing ALB
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
          - path: /api/patients
            pathType: Prefix
            backend:
              service:
                name: patient-service
                port:
                  number: 8001
          - path: /api/appointments
            pathType: Prefix
            backend:
              service:
                name: appointment-service
                port:
                  number: 8002
```

> 🧠 **The Ingress only exposes patient-service and appointment-service.**
> audit-service and notification-service are internal — they should never be reachable
> from the public internet. This is the same principle as keeping your database in a
> private subnet in v1.

**For minikube testing (no ALB)**, use a simple minikube Ingress instead:
```bash
minikube addons enable ingress
```
And change the annotation to `kubernetes.io/ingress.class: nginx`.

---

## 7. Apply Everything to minikube

```bash
# Start minikube if not running
minikube start --cpus=2 --memory=4g

# Point Docker at minikube's daemon and build images
eval $(minikube docker-env)
for svc in patient-service appointment-service audit-service notification-service; do
  (cd services/$svc && docker build -t $svc:local .)
done

# Create namespaces
kubectl apply -f k8s/base/namespaces.yaml

# Apply all service manifests
kubectl apply -f k8s/base/patient-service.yaml
kubectl apply -f k8s/base/appointment-service.yaml
kubectl apply -f k8s/base/audit-service.yaml
kubectl apply -f k8s/base/notification-service.yaml
```

Watch everything come up:
```bash
kubectl get pods -n dev -w
# NAME                                    READY   STATUS    RESTARTS   AGE
# patient-service-5d8b7f6c4-xk2pq        1/1     Running   0          30s
# appointment-service-7c9f8d5b2-m3np1    1/1     Running   0          28s
# audit-service-6b8c9f4d1-p7qr2          1/1     Running   0          25s
# notification-service-4f7d8a3c0-r9st3   1/1     Running   0          22s
```

All four pods at `1/1 Running`. The `1/1` means 1 container running out of 1 ready.

---

## 8. Verifying Inter-Service Communication

Port-forward patient-service and create a patient:
```bash
kubectl port-forward svc/patient-service 8001:8001 -n dev &

curl -X POST http://localhost:8001/patients \
  -H "Content-Type: application/json" \
  -d '{"full_name": "Nimal Silva", "date_of_birth": "1985-03-15", "phone": "077-123-4567"}'
# {"id": 1, ...}
```

Port-forward appointment-service and create an appointment (uses patient_id=1):
```bash
kubectl port-forward svc/appointment-service 8002:8002 -n dev &

curl -X POST http://localhost:8002/appointments \
  -H "Content-Type: application/json" \
  -d '{"patient_id": 1, "scheduled_for": "2026-07-15T09:00:00", "reason": "Annual checkup"}'
```

If the appointment succeeds, appointment-service successfully called patient-service
through Kubernetes DNS. That's inter-service communication working inside the cluster.

---

## 9. Useful Debugging Commands

```bash
# See all resources in the dev namespace at once
kubectl get all -n dev

# Why is a pod not starting?
kubectl describe pod <pod-name> -n dev
# Look at: Events section at the bottom — "Failed to pull image", "CrashLoopBackOff"

# View logs
kubectl logs <pod-name> -n dev

# View logs from a previous (crashed) container
kubectl logs <pod-name> -n dev --previous

# Execute a shell inside a running pod
kubectl exec -it <pod-name> -n dev -- /bin/sh

# Get the full YAML of a running resource (great for seeing what Kubernetes adds)
kubectl get deployment patient-service -n dev -o yaml
```

---

## ✅ Checkpoint

You should be able to answer:

- What is the difference between a Pod and a Deployment?
- What does a Service do? Why can't you call a pod directly by IP?
- What does `selector.matchLabels` match to?
- What is the difference between `readinessProbe` and `livenessProbe`?
- Why don't audit-service and notification-service have Ingress rules?
- What does `kubectl get pods -n dev -w` show you?

Next: **[04 — Helm Charts](04-helm-charts.md)** — package these manifests into Helm
charts so you can manage dev/prod differences with value overrides instead of
duplicate YAML files.
