# 01 — Local Setup

> **Goal of this doc:** install every tool you need and understand what each one does —
> so you are fully ready before writing a single line of code.
>
> ⚠️ **Important ordering note:** We install tools here, but we do NOT run the services
> yet. The services don't exist yet — we write all the code in **Doc 02**. After Doc 02
> you'll come back and run `docker compose up` for the first time. Then in this same doc
> you'll run the services on minikube.

Everything in this doc costs **zero dollars**. We're building on your laptop.

---

## 1. Tools You Need

You likely have some of these from CloudCare v1. Install anything missing and verify
each one before continuing.

### 1.1 Docker Desktop

Docker Desktop includes the Docker daemon (runs containers), Docker Compose (runs
multiple containers together), and `kubectl` (the Kubernetes CLI).

**Install:**
- Download: https://www.docker.com/products/docker-desktop/
- After install, open Docker Desktop and wait for the green "Running" indicator.

**Verify:**
```bash
docker --version
# Docker version 27.x.x, build ...

docker compose version
# Docker Compose version v2.x.x

kubectl version --client
# Client Version: v1.30.x
```

> 🧠 **What is kubectl?** It's the command-line tool for talking to a Kubernetes
> cluster — the same way the `aws` CLI talks to AWS. Every `kubectl` command follows
> the pattern: `kubectl <verb> <resource-type> <name> -n <namespace>`.
> You'll use it dozens of times per day.

---

### 1.2 minikube

minikube runs a single-node Kubernetes cluster on your laptop inside a Docker container.
It's the standard tool for local Kubernetes development — completely free.

**Install:**
```bash
# macOS
brew install minikube

# Linux (Ubuntu/Debian)
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64

# Windows (PowerShell as Admin)
choco install minikube
```

**Verify:**
```bash
minikube version
# minikube version: v1.33.x
# commit: ...
```

---

### 1.3 Helm 3

Helm is the package manager for Kubernetes. You use it to install applications on a
cluster — the same way `apt` or `npm` manages packages on a machine.

**Install:**
```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Windows
choco install kubernetes-helm
```

**Verify:**
```bash
helm version
# version.BuildInfo{Version:"v3.15.x", ...}
```

---

### 1.4 Terraform >= 1.9

You already have this from CloudCare v1. If not:

```bash
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Linux — use tfenv (manages multiple Terraform versions)
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
tfenv install 1.9.0
tfenv use 1.9.0
```

**Verify:**
```bash
terraform version
# Terraform v1.9.x
# on linux_amd64
```

---

### 1.5 Python 3.12 + pip

The four microservices are all written in Python 3.12.

```bash
# macOS
brew install python@3.12
echo 'export PATH="/opt/homebrew/opt/python@3.12/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Ubuntu/Debian
sudo apt update
sudo apt install python3.12 python3.12-venv python3-pip -y

# Verify
python3.12 --version
# Python 3.12.x
pip3 --version
# pip 24.x from ...
```

---

### 1.6 Node.js 20+

For the React frontend.

```bash
# macOS
brew install node@20
echo 'export PATH="/opt/homebrew/opt/node@20/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Verify
node --version
# v20.x.x
npm --version
# 10.x.x
```

---

### 1.7 AWS CLI v2

Already installed from CloudCare v1. Verify:
```bash
aws --version
# aws-cli/2.x.x Python/3.x.x ...
aws sts get-caller-identity
# Should return your account ID without errors
```

---

### 1.8 Summary Checklist

Run all of these before continuing. Every single one must succeed:

```bash
docker --version          # Docker version 27+
docker compose version    # Docker Compose version v2+
kubectl version --client  # Client Version v1.30+
minikube version          # minikube version v1.33+
helm version              # Version:"v3.15+"
terraform version         # Terraform v1.9+
python3.12 --version      # Python 3.12+
node --version            # v20+
aws --version             # aws-cli/2+
```

If any of these fail, fix them before moving on. Don't skip ahead — a broken tool
will silently cause problems 10 steps later.

---

## 2. Docker Compose vs Kubernetes — What's the Difference?

Before writing code, understand why we use two different tools and when.

### Docker Compose

Runs multiple containers **on one machine**. You describe every service in a single
`docker-compose.yml` file and start them all with `docker compose up`. It is:
- Simple to set up
- Fast to iterate on
- Perfect for local development

### Kubernetes

Runs containers across a **cluster of machines**. It:
- Keeps pods running if they crash
- Scales pods up and down automatically
- Performs zero-downtime rolling updates
- Manages networking between services across nodes
- Is the industry standard for production

> 🧠 **Why not just use Kubernetes locally from day one?**
> Kubernetes has many moving parts. While you're still learning how the FastAPI code
> works and how microservices talk to each other, adding Kubernetes complexity makes
> everything harder to debug. The pattern used by real engineering teams: Docker Compose
> for local development iteration, Kubernetes for staging and production.

### The workflow we follow in this project:

```
Step 1 (Doc 02): Write all the Python code for 4 microservices
Step 2 (Doc 02): Run with Docker Compose → fast feedback, easy debugging
Step 3 (Doc 03): Write Kubernetes YAML manifests
Step 4 (Doc 03): Run on minikube → same code, Kubernetes behaviour
Step 5 (Doc 05): Deploy to real EKS on AWS
```

---

## 3. minikube — Your Local Kubernetes Cluster

We'll use minikube fully starting in Doc 03, but here's what you need to know now.

### Start and Stop minikube

```bash
# Start a cluster (first time takes 2–3 minutes to download images)
minikube start --cpus=2 --memory=4g --driver=docker

# Check the cluster is healthy
kubectl get nodes
# NAME       STATUS   ROLES           AGE   VERSION
# minikube   Ready    control-plane   60s   v1.30.x

# Stop the cluster (keeps all state — pods, namespaces, deployments)
minikube stop

# Delete the cluster completely (start fresh next time)
minikube delete
```

The `Ready` status on the node means the cluster is healthy and ready for workloads.

### What minikube Creates

```
minikube cluster (one Docker container on your machine)
│
└── Single Kubernetes node
    ├── Kubernetes control plane (API server, scheduler, etcd)
    └── Worker capacity (your pods run here)
```

In production EKS, the control plane is managed by AWS (~$0.10/hr) and worker nodes
are separate EC2 instances. minikube combines all of this into one Docker container —
free, and fast to start.

---

## 4. kubectl — Your Daily Command Reference

You'll type `kubectl` hundreds of times. Memorise this cheatsheet.

### Viewing Resources

```bash
# List all pods in a namespace
kubectl get pods -n dev

# List pods in ALL namespaces at once
kubectl get pods -A

# List everything in a namespace (pods, services, deployments...)
kubectl get all -n dev

# See full details of a resource (great for debugging)
kubectl describe pod <pod-name> -n dev
kubectl describe deployment patient-service -n dev

# See the full YAML of a running resource
kubectl get deployment patient-service -n dev -o yaml
```

### Logs and Debugging

```bash
# View logs of a pod
kubectl logs <pod-name> -n dev

# Follow logs live (like tail -f)
kubectl logs -f <pod-name> -n dev

# View logs from a crashed/previous container
kubectl logs <pod-name> -n dev --previous

# Open a shell inside a running pod
kubectl exec -it <pod-name> -n dev -- /bin/sh
```

### Applying and Deleting

```bash
# Apply a manifest file (create or update)
kubectl apply -f deployment.yaml

# Apply everything in a directory
kubectl apply -f k8s/base/

# Delete resources defined in a file
kubectl delete -f deployment.yaml

# Delete a resource by type and name
kubectl delete pod <pod-name> -n dev
kubectl delete deployment patient-service -n dev
```

### Namespaces

```bash
# Create a namespace
kubectl create namespace dev

# List all namespaces
kubectl get namespaces

# Set a default namespace so you don't type -n every time
kubectl config set-context --current --namespace=dev
```

### Port Forwarding

```bash
# Forward a service port to localhost (run in background with &)
kubectl port-forward svc/patient-service 8001:8001 -n dev &

# Now call it from another terminal:
curl http://localhost:8001/patients

# Kill the port-forward when done:
kill %1
```

> 🧠 **Why port-forward?** Services in Kubernetes are not accessible from outside
> the cluster by default (ClusterIP). Port-forward creates a temporary tunnel from
> your laptop's port to the service inside the cluster. It's only for testing —
> in production, use Ingress.

### Watching Changes in Real Time

```bash
# Watch pods update (useful during deploys)
kubectl get pods -n dev -w

# You'll see:
# NAME                               READY   STATUS              RESTARTS
# patient-service-abc123-old         1/1     Terminating         0
# patient-service-def456-new         0/1     ContainerCreating   0
# patient-service-def456-new         1/1     Running             0
```

---

## 5. What Happens in minikube vs Docker Compose

Once you've written the code in Doc 02 and run it with Docker Compose, you'll move
to Kubernetes in Doc 03. Here's how the two compare:

| Concern | Docker Compose | Kubernetes (minikube) |
|---|---|---|
| Start | `docker compose up` | `kubectl apply -f deployment.yaml` |
| Service discovery | `http://patient-service:8001` | `http://patient-service:8001` (same!) |
| Access from laptop | Port published automatically | `kubectl port-forward` |
| Crash recovery | `restart: always` | Automatic (Deployment controller) |
| Scale | `docker compose scale svc=3` | Edit `replicas: 3`, apply |
| Rolling update | Stop + start | Zero-downtime rolling deploy |
| Config | Env vars in compose file | ConfigMap or Secret |
| Secrets | Env vars in compose file | Kubernetes Secret or External Secrets |

Notice: **service discovery DNS works the same in both**. A service calling
`http://patient-service:8001` works in Docker Compose and in Kubernetes. That's
intentional — it makes it easy to move code between environments.

---

## ✅ Checkpoint — What to Do Now

Before continuing:

- [ ] All 9 tools verified above show the correct versions
- [ ] `minikube start` completes and `kubectl get nodes` shows `Ready`
- [ ] `minikube stop` stops the cluster cleanly

**Do NOT try to run the services yet.** The code doesn't exist yet.

**Next step:** Go to **[02 — Microservices Split](02-microservices-split.md)** and
write all the Python code for the four services. At the end of Doc 02, you'll
run `docker compose up` for the first time and see all services working.

After Doc 02, come back here and continue to the minikube section below.

---

## 6. Running the Services on minikube (Do This After Doc 02)

> **Come back to this section after completing Doc 02.** The steps below assume you
> have already written all the Python code and tested it with Docker Compose.

### 6.1 Build Images Inside minikube

minikube has its own Docker daemon. You must build images inside it so Kubernetes
can find them without needing a registry:

```bash
# Point your shell's Docker to minikube's daemon
eval $(minikube docker-env)

# Verify — you should see minikube's images, not your local ones
docker images

# Build all four service images inside minikube
cd /path/to/cloud-care-k8s/services

for svc in patient-service appointment-service audit-service notification-service; do
  echo "Building $svc..."
  (cd $svc && docker build -t $svc:local .)
done

# Verify images were built
docker images | grep -E "patient|appointment|audit|notification"
```

### 6.2 Create Namespaces

```bash
kubectl create namespace dev
kubectl get namespaces
# NAME          STATUS   AGE
# default       Active   5m
# dev           Active   2s
# kube-system   Active   5m
```

### 6.3 Quick Smoke Test on minikube

Create a test manifest `patient-service-smoke.yaml` to verify the image runs:

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
          imagePullPolicy: Never
          ports:
            - containerPort: 8001
          env:
            - name: DATABASE_URL
              value: "sqlite:///./test.db"
            - name: DB_SCHEMA
              value: "main"
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

Apply and test:
```bash
kubectl apply -f patient-service-smoke.yaml

# Watch until Running
kubectl get pods -n dev -w
# patient-service-xxx   1/1   Running   0   30s

# Port-forward and test
kubectl port-forward svc/patient-service 8001:8001 -n dev &
curl http://localhost:8001/health
# {"status": "ok", "service": "patient-service"}

curl http://localhost:8001/patients
# []

# Clean up
kubectl delete -f patient-service-smoke.yaml
```

### 6.4 Stop minikube When Done

```bash
minikube stop
```

**You are now ready for Doc 03** — Kubernetes Manifests, where we write proper
production-quality YAML for all four services.

---

> 🧠 **Remember:** Everything from Doc 01 through Doc 04 runs on minikube —
> completely free. The first time we spend money is Doc 05 when we create the real
> EKS cluster on AWS (~$2.40/day). Keep minikube stopped when you're not using it
> to avoid unnecessary CPU usage on your laptop.
