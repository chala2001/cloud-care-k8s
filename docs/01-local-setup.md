# 01 — Local Setup

> **Goal of this doc:** install every tool you need, run all four microservices with
> Docker Compose, and get a pod running on minikube — before touching AWS at all.

Everything in this doc costs **zero dollars**. We're building on your laptop.

---

## 1. Tools You Need

You likely have some of these from CloudCare v1. Install anything missing.

### 1.1 Docker Desktop

Docker Desktop includes both the Docker daemon **and** `kubectl` (the Kubernetes CLI).

- Download: https://www.docker.com/products/docker-desktop/
- After install, open Docker Desktop and wait for the green "Running" indicator.
- Verify:

```bash
docker --version
# Docker version 27.x.x, build ...

kubectl version --client
# Client Version: v1.30.x
```

> 🧠 **What is kubectl?** It's the command-line tool for talking to a Kubernetes cluster —
> the same way `aws` CLI talks to AWS. Every `kubectl` command you'll ever run follows
> the pattern: `kubectl <verb> <resource-type> <name> -n <namespace>`.

### 1.2 minikube

minikube runs a single-node Kubernetes cluster on your laptop, inside a VM or Docker
container. It's the standard tool for local Kubernetes development.

```bash
# macOS (Homebrew)
brew install minikube

# Linux
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Windows (Chocolatey)
choco install minikube
```

Verify:
```bash
minikube version
# minikube version: v1.33.x
```

### 1.3 Helm 3

Helm is the package manager for Kubernetes. You use it to install and upgrade
applications on a cluster — the same way `apt` or `npm` manages packages.

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Windows
choco install kubernetes-helm
```

Verify:
```bash
helm version
# version.BuildInfo{Version:"v3.15.x", ...}
```

### 1.4 Terraform (already installed from v1)

If you don't have it:
```bash
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Linux (via tfenv — manages multiple versions)
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
tfenv install 1.9.0 && tfenv use 1.9.0
```

Verify:
```bash
terraform version
# Terraform v1.9.x
```

### 1.5 Python 3.12 + pip

```bash
# macOS
brew install python@3.12

# Ubuntu/Debian
sudo apt install python3.12 python3.12-venv python3-pip

# Verify
python3.12 --version   # Python 3.12.x
pip3 --version
```

### 1.6 Node.js 20+

```bash
# macOS
brew install node@20

# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Verify
node --version   # v20.x.x
npm --version
```

### 1.7 AWS CLI v2 (already installed from v1)

```bash
aws --version
# aws-cli/2.x.x Python/3.x.x ...
```

---

## 2. Understanding Docker Compose vs Kubernetes

Before we run anything, let's understand why we use Docker Compose locally and
Kubernetes in production.

**Docker Compose** is a simple tool for running multiple containers together on one
machine. You define all your services in a `docker-compose.yml` file and start them
with one command. It's perfect for local development because it's fast and simple.

**Kubernetes** is a container *orchestrator* — it runs containers across a *cluster* of
machines, handles failures, scales automatically, manages networking between services,
and much more. It's the industry standard for production.

> 🧠 **Why not just use Kubernetes locally from day one?**
> Kubernetes has a lot of moving parts. If you're still learning FastAPI code structure
> and microservice boundaries, adding Kubernetes overhead makes everything harder.
> Use Docker Compose to understand the *application*, then add Kubernetes to understand
> the *infrastructure*. This is exactly how real teams work — compose for local dev,
> Kubernetes for everything else.

---

## 3. Running All Services with Docker Compose

The project has a `docker-compose.yml` in the `services/` directory that starts all
four microservices plus a local PostgreSQL and DynamoDB.

### 3.1 Docker Compose File

Here is what the `services/docker-compose.yml` looks like:

```yaml
version: "3.9"

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: cloudcare
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: local_password
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql

  patient-service:
    build: ./patient-service
    ports:
      - "8001:8001"
    environment:
      DATABASE_URL: "postgresql://patient_svc:patient_pass@postgres:5432/cloudcare"
      DB_SCHEMA: patients
    depends_on:
      - postgres

  appointment-service:
    build: ./appointment-service
    ports:
      - "8002:8002"
    environment:
      DATABASE_URL: "postgresql://appt_svc:appt_pass@postgres:5432/cloudcare"
      DB_SCHEMA: appointments
      PATIENT_SERVICE_URL: "http://patient-service:8001"
    depends_on:
      - postgres
      - patient-service

  audit-service:
    build: ./audit-service
    ports:
      - "8003:8003"
    environment:
      DYNAMODB_TABLE: audit_events
      AWS_DEFAULT_REGION: ap-south-1
      # Local dev: uses a fake DynamoDB (DynamoDB Local)
      DYNAMODB_ENDPOINT_URL: "http://dynamodb-local:8000"
    depends_on:
      - dynamodb-local

  notification-service:
    build: ./notification-service
    ports:
      - "8004:8004"
    environment:
      SES_FROM_ADDRESS: "noreply@example.com"
      # Local dev: email is just logged, not actually sent

  dynamodb-local:
    image: amazon/dynamodb-local
    ports:
      - "8000:8000"

volumes:
  postgres_data:
```

**Key things to notice:**
- Each service has its own port (`8001`, `8002`, `8003`, `8004`)
- `appointment-service` knows `patient-service` by its service name (`http://patient-service:8001`)
  — Docker Compose creates an internal DNS for this
- Each service gets its DB credentials via environment variables — same pattern as Kubernetes
- Local DynamoDB (`amazon/dynamodb-local`) replaces real AWS DynamoDB for local testing

### 3.2 Start All Services

```bash
cd services/
docker compose up --build
```

You'll see output from all containers interleaved. After everything starts (30–60 seconds):

```bash
# Open Swagger UI for each service:
# patient-service      → http://localhost:8001/docs
# appointment-service  → http://localhost:8002/docs
# audit-service        → http://localhost:8003/docs
# notification-service → http://localhost:8004/docs
```

### 3.3 Test the Services

Open `http://localhost:8001/docs` — you'll see FastAPI's interactive Swagger UI.

Try creating a patient:
```bash
curl -X POST http://localhost:8001/patients \
  -H "Content-Type: application/json" \
  -d '{"full_name": "Nimal Silva", "date_of_birth": "1985-03-15", "phone": "0771234567"}'

# Response: {"id": 1, "full_name": "Nimal Silva", ...}
```

Try creating an appointment (uses the patient ID from above):
```bash
curl -X POST http://localhost:8002/appointments \
  -H "Content-Type: application/json" \
  -d '{"patient_id": 1, "scheduled_for": "2026-07-01T10:00:00", "reason": "Annual checkup"}'
```

The appointment-service will call patient-service internally to verify the patient exists.
That's inter-service communication — the core of microservices.

### 3.4 Stop Everything

```bash
docker compose down          # stop containers, keep volumes
docker compose down -v       # stop containers AND delete data volumes
```

---

## 4. Your First Kubernetes Pod on minikube

Now we'll run the same application on Kubernetes. This is intentionally simplified —
we'll cover the full manifest structure in Doc 03.

### 4.1 Start minikube

```bash
minikube start --cpus=2 --memory=4g --driver=docker
```

This creates a single-node Kubernetes cluster running inside a Docker container on your
machine. It takes 1–2 minutes the first time.

Verify:
```bash
kubectl get nodes
# NAME       STATUS   ROLES           AGE   VERSION
# minikube   Ready    control-plane   30s   v1.30.x
```

`Ready` means the cluster is healthy and ready to accept workloads.

### 4.2 Key kubectl Commands You'll Use Every Day

```bash
# Get all pods in a namespace
kubectl get pods -n <namespace>

# Get all pods in ALL namespaces
kubectl get pods -A

# Describe a pod (full details, great for debugging)
kubectl describe pod <pod-name> -n <namespace>

# View logs from a pod
kubectl logs <pod-name> -n <namespace>

# Follow logs live (like tail -f)
kubectl logs -f <pod-name> -n <namespace>

# Execute a command inside a pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Port-forward a service to your localhost
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>

# Apply a manifest file
kubectl apply -f <file.yaml>

# Delete a resource
kubectl delete -f <file.yaml>
# OR
kubectl delete pod <pod-name> -n <namespace>
```

> 🧠 **Namespaces** in Kubernetes are like logical partitions within a cluster.
> We use `dev` and `prod` namespaces to keep environments isolated.
> If you don't specify `-n <namespace>`, kubectl uses the `default` namespace.

### 4.3 Run patient-service on minikube (Quick Test)

Let's run a simplified version of patient-service on minikube to see how pods work.

First, build the image inside minikube (so minikube can find it without a registry):

```bash
# Point your Docker CLI at minikube's Docker daemon
eval $(minikube docker-env)

# Now build the image — it goes into minikube, not your local Docker
cd services/patient-service
docker build -t patient-service:local .
```

Now create a namespace and run the pod:

```bash
kubectl create namespace dev
```

Create a file called `patient-service-test.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: patient-service
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: patient-service
  template:
    metadata:
      labels:
        app: patient-service
    spec:
      containers:
        - name: patient-service
          image: patient-service:local
          imagePullPolicy: Never    # use local image, don't pull from registry
          ports:
            - containerPort: 8001
          env:
            - name: DATABASE_URL
              value: "sqlite:///./test.db"   # SQLite for this quick test
---
apiVersion: v1
kind: Service
metadata:
  name: patient-service
  namespace: dev
spec:
  selector:
    app: patient-service
  ports:
    - port: 8001
      targetPort: 8001
```

Apply it:
```bash
kubectl apply -f patient-service-test.yaml
```

Watch the pod come up:
```bash
kubectl get pods -n dev -w
# NAME                               READY   STATUS    RESTARTS   AGE
# patient-service-7d9f8b6c9-xk2pq   1/1     Running   0          15s
```

Once `Running`, port-forward and test:
```bash
kubectl port-forward svc/patient-service 8001:8001 -n dev
# In another terminal:
curl http://localhost:8001/patients
```

Congratulations — you just ran a containerised service on Kubernetes.

### 4.4 Clean Up

```bash
kubectl delete -f patient-service-test.yaml
# or delete the whole namespace
kubectl delete namespace dev
```

To stop minikube (keeps the cluster state):
```bash
minikube stop
```

To fully delete the minikube cluster:
```bash
minikube delete
```

---

## 5. Understanding the Difference: What Kubernetes Added

Compare what happened in Docker Compose vs Kubernetes:

| | Docker Compose | Kubernetes |
|---|---|---|
| Start a service | `docker compose up` | `kubectl apply -f deployment.yaml` |
| Discovery between services | Service name (e.g., `patient-service`) | Service name (e.g., `patient-service.dev.svc.cluster.local`) |
| Access from outside | Expose port directly | Port-forward or Ingress |
| Restart on crash | `restart: always` in compose | Always restarts by default |
| Scale | `docker compose scale patient-service=3` | Change `replicas: 3` in the Deployment |
| Rolling update | Stop and restart | Zero-downtime rolling deploy |
| Config / secrets | Environment variables | ConfigMaps and Secrets |

The Kubernetes way is more complex, but everything is declarative (YAML files),
version-controlled, and reproducible.

---

## ✅ Checkpoint

Before moving on, confirm:

- [ ] `docker compose up` starts all 4 services and you can hit `http://localhost:8001/docs`
- [ ] `minikube start` succeeds and `kubectl get nodes` shows `Ready`
- [ ] You can run `kubectl apply -f patient-service-test.yaml` and see the pod reach `Running`
- [ ] You can port-forward and hit `http://localhost:8001/patients`

If all four are checked, you're ready for the next step.

Next: **[02 — Microservices Split](02-microservices-split.md)** — understand how the
monolith from v1 is split into four independent services and why each boundary was
drawn where it was.
