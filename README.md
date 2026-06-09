# CloudCare-K8s — AWS DevOps Showcase v2

> **The evolution of CloudCare.**
> Same hospital management system. Migrated from a monolithic EC2/ASG deployment
> to a **microservices architecture orchestrated on Kubernetes** — the way modern
> engineering teams actually run production workloads.

**Region** `ap-south-1` (Mumbai) · **IaC** Terraform 1.9+ · **Orchestration** Kubernetes 1.30 on EKS
**Backend** Python 3.12 + FastAPI (4 microservices) · **Frontend** React 18 + Vite
**CI/CD** GitHub Actions + OIDC · **Observability** Prometheus + Grafana + Loki

---

## What This Project Is

CloudCare-K8s takes the hospital management app from [CloudCare v1](../cloud-care) and
re-platforms it onto Kubernetes to demonstrate how modern engineering teams operate
containerised workloads. The application logic (patients, appointments) is intentionally
minimal CRUD — the interesting work lives in `terraform/`, `helm/`, `k8s/`, and
`.github/workflows/`.

> **UI/UX is out of scope.** The frontend exists to prove the stack is wired up end-to-end.
> Read the Terraform stacks, the Helm charts, the GitHub Actions workflows, and the
> architecture sections to evaluate this project.

---

## How v2 Differs from CloudCare v1

| Concern | CloudCare v1 (EC2/ASG) | CloudCare-K8s v2 (EKS) |
|---|---|---|
| Deployment unit | Single FastAPI monolith | 4 independent microservices |
| Compute | EC2 Auto Scaling Group | EKS node group (t3.micro) |
| Scaling | ASG instance-refresh (~5 min) | HPA pod scale-out (~30 sec) |
| Rollout strategy | New AMI, wait for health check | Kubernetes rolling deploy |
| Rollback | Re-push previous image | `helm rollback <service> <revision>` |
| Image tagging | `:latest` | Git SHA (`:abc1234`) — immutable |
| Secrets | Fetched at EC2 boot | External Secrets Operator → pod env |
| Observability | CloudWatch only | Prometheus + Grafana + Loki + CloudWatch |
| Config management | Env vars baked into launch template | ConfigMaps + Secrets per namespace |
| Multi-environment | Single environment | `dev` and `prod` namespaces |
| CI/CD scope | One pipeline for the whole backend | One pipeline **per service** |

**Interview narrative:**
*"I built CloudCare on traditional AWS infrastructure to understand the fundamentals.
Then I re-platformed it onto Kubernetes to learn how modern teams actually operate
containerised workloads — independent deployments, faster rollouts, and a proper
observability stack."*

---

## Architecture at a Glance

```
Users
  │
  ▼
CloudFront (HTTPS)
  ├── /             → S3 (React SPA, private via OAC)
  └── /api/*        → ALB (Ingress Controller)
                          │
                    ┌─────▼──────────────────────────────┐
                    │           EKS Cluster               │
                    │  ┌────────────────────────────┐    │
                    │  │  patient-service     :8001  │    │
                    │  │  appointment-service :8002  │    │
                    │  │  audit-service       :8003  │    │
                    │  │  notification-service:8004  │    │
                    │  └──────────────┬─────────────┘    │
                    └─────────────────┼──────────────────┘
                                      │
                    ┌─────────────────▼──────────────────┐
                    │       RDS PostgreSQL (private)      │
                    │   schema: patients                  │
                    │   schema: appointments              │
                    └────────────────────────────────────┘

Monitoring (runs in cluster):
  Prometheus → scrapes all services + nodes
  Grafana    → dashboards
  Loki       → log aggregation via Promtail
```

---

## Microservices Breakdown

Each service is independently deployable with its own Docker image, ECR repo, Helm chart,
GitHub Actions workflow, and database schema.

| Service | Port | Owns | Tech |
|---|---|---|---|
| patient-service | 8001 | `patients` PostgreSQL schema | Python 3.12, FastAPI |
| appointment-service | 8002 | `appointments` PostgreSQL schema | Python 3.12, FastAPI |
| audit-service | 8003 | DynamoDB `audit_events` table | Python 3.12, FastAPI |
| notification-service | 8004 | Nothing persistent — calls SES | Python 3.12, FastAPI |

---

## Tech Stack

### Cloud & Orchestration
| Tool | Role |
|---|---|
| AWS EKS | Managed Kubernetes control plane |
| Terraform 1.9+ | All infrastructure declared as code |
| Helm 3 | Package manager for Kubernetes manifests |
| Kustomize | Overlay system for dev/prod environment differences |

### Compute & Networking
| Tool | Role |
|---|---|
| EKS Node Group | t3.micro worker nodes (free-tier eligible) |
| AWS ALB Ingress Controller | Routes external traffic into the cluster |
| CloudFront | HTTPS edge, caches static SPA assets |
| S3 (private) | React build output, accessed via OAC |
| NAT Instance | Outbound internet for private subnets (saves ~$32/mo vs NAT GW) |

### Data
| Tool | Role |
|---|---|
| RDS PostgreSQL 16 | Relational data, schema-per-service isolation |
| DynamoDB | Audit events (write-heavy, no joins needed) |
| AWS Secrets Manager | DB credentials, fetched by External Secrets Operator |
| External Secrets Operator | Syncs Secrets Manager → Kubernetes Secrets automatically |

### Observability
| Tool | Role |
|---|---|
| Prometheus | Metrics scraping from all pods and node exporters |
| Grafana | Dashboards for service health, latency, error rates |
| Loki | Log aggregation from all pods via Promtail |
| CloudWatch | AWS-native metrics (RDS, ALB, EKS control plane) |
| X-Ray | Distributed traces on audit and notification paths |

### CI/CD & Identity
| Tool | Role |
|---|---|
| GitHub Actions | All build, test, and deploy pipelines |
| GitHub OIDC | Keyless AWS authentication — no stored credentials |
| ECR | Private container registry, one repo per service |

---

## Engineering Practices Demonstrated

| # | Practice | Where to find it |
|---|---|---|
| 1 | Microservices decomposition — logical boundaries, independent deployability | `services/`, `helm/`, `.github/workflows/` |
| 2 | Kubernetes-native scaling — HPA replaces ASG instance-refresh | `helm/*/templates/hpa.yaml` |
| 3 | Immutable image tags — git SHA, not `:latest` | every `*-service.yml` workflow |
| 4 | GitOps deployment — Helm chart is source of truth, CI applies it | `helm/`, workflows |
| 5 | IRSA least-privilege — pod-level AWS permissions, not node-level | `terraform/eks/irsa.tf` |
| 6 | External Secrets Operator — secrets live in Secrets Manager, not Git | `helm/*/templates/externalsecret.yaml` |
| 7 | Multi-environment with manual approval gate | `deploy-prod` job, GitHub environments |
| 8 | Three-pillar observability — Prometheus, Grafana, Loki | `monitoring/` |
| 9 | Keyless CI/CD — OIDC, no stored AWS keys, sub claim pinned | `terraform/eks/oidc.tf` |
| 10 | Database-per-service pattern — schema isolation with documented upgrade path | `docs/02-microservices-split.md` |

---

## Repository Structure

```
cloudcare-k8s/
│
├── services/                          ← one directory per microservice
│   ├── patient-service/
│   │   ├── app/                       ← FastAPI source code
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── tests/                     ← pytest unit tests
│   ├── appointment-service/
│   ├── audit-service/
│   └── notification-service/
│
├── frontend/                          ← React 18 + Vite
│   ├── src/
│   ├── index.html
│   └── package.json
│
├── terraform/                         ← 3 stacks, each with its own state key
│   ├── bootstrap/                     ← S3 state bucket + DynamoDB lock (run once)
│   ├── eks/                           ← VPC, EKS cluster, node group, IAM, ECR repos
│   └── platform/                      ← RDS, Secrets Manager, ALB Ingress Controller,
│                                          External Secrets Operator, CloudFront, S3
│
├── helm/                              ← one Helm chart per service
│   ├── patient-service/
│   │   ├── Chart.yaml
│   │   ├── values.yaml                ← base values
│   │   ├── values-dev.yaml
│   │   ├── values-prod.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       └── externalsecret.yaml
│   └── ... (one chart per service)
│
├── k8s/                               ← raw manifests (Kustomize)
│   ├── base/
│   └── overlays/
│       ├── dev/
│       └── prod/
│
├── monitoring/
│   ├── prometheus/
│   ├── grafana/dashboards/
│   └── loki/
│
├── .github/workflows/
│   ├── patient-service.yml
│   ├── appointment-service.yml
│   ├── audit-service.yml
│   ├── notification-service.yml
│   ├── frontend.yml
│   └── terraform.yml
│
└── docs/                              ← numbered guides, one per phase
    ├── 00-roadmap.md
    ├── 01-local-setup.md
    ├── 02-microservices-split.md
    ├── 03-k8s-manifests.md
    ├── 04-helm-charts.md
    ├── 05-eks-terraform.md
    ├── 06-cicd.md
    ├── 07-secrets.md
    ├── 08-hpa.md
    ├── 09-observability.md
    └── 10-multi-env.md
```

---

## Prerequisites

- **AWS account** with a non-root IAM admin user and MFA enabled (see [v1 Doc 03](../cloud-care/docs/03-aws-account-and-cost-safety.md))
- **AWS CLI v2** authenticated (`aws sts get-caller-identity` succeeds)
- **Terraform** `>= 1.9`
- **Docker Desktop** (includes kubectl)
- **minikube** or **kind** for local Kubernetes
- **Helm 3** (`helm version`)
- **Node.js 20+** (for the frontend)
- **Python 3.12** (for local backend dev)

---

## Quick Start — Deploy from Scratch

### Phase 0 — Bootstrap Terraform state

```bash
export AWS_PROFILE=cloudcare-k8s
export AWS_REGION=ap-south-1

cd terraform/bootstrap
terraform init
terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"
```

### Phase 1 — Provision EKS cluster

```bash
cd terraform/eks
terraform init && terraform apply
# ⚠️  EKS control plane starts billing (~$2.40/day) from this point.

aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1
kubectl get nodes  # should show 2 t3.micro nodes
```

### Phase 2 — Provision platform resources

```bash
cd terraform/platform
terraform init && terraform apply
# Provisions: RDS, Secrets Manager, ALB Ingress Controller,
#             External Secrets Operator, S3, CloudFront
```

### Phase 3 — Build images and deploy services

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1

for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  aws ecr get-login-password | docker login --username AWS --password-stdin \
    "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  ( cd services/$svc && docker build -t "$ECR:latest" . && docker push "$ECR:latest" )
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.tag=latest \
    --namespace prod --create-namespace
done
```

### Phase 4 — Deploy frontend

```bash
BUCKET=$(cd terraform/platform && terraform output -raw frontend_bucket)
DIST=$(cd terraform/platform && terraform output -raw cloudfront_distribution_id)

cd frontend && npm ci && npm run build
aws s3 sync dist/ "s3://$BUCKET/" --delete
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

### Teardown (return to ~$0)

```bash
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod
done

for stack in platform eks bootstrap; do
  ( cd terraform/$stack && terraform destroy -auto-approve )
done
```

---

## Local Development

### Run all services with Docker Compose

```bash
cd services/
docker compose up --build
# patient-service      → http://localhost:8001/docs
# appointment-service  → http://localhost:8002/docs
# audit-service        → http://localhost:8003/docs
# notification-service → http://localhost:8004/docs
```

### Run on local Kubernetes (minikube)

```bash
minikube start --cpus=2 --memory=4g

helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev --create-namespace

kubectl get pods -n dev -w
kubectl port-forward svc/patient-service 8001:8001 -n dev
```

---

## Cost

Designed to stay within the AWS Free Tier.

| Resource | Est. monthly cost | Notes |
|---|---|---|
| EKS control plane | ~$73 | No free tier — biggest cost |
| 2× t3.micro worker nodes | ~$0 | 750 hrs/mo free tier |
| RDS db.t3.micro | ~$0 | 750 hrs/mo free tier |
| ALB | ~$16 | Fixed hourly + LCU |
| NAT instance (t3.micro) | ~$0 | Free tier; saves ~$32 vs NAT GW |
| CloudFront | ~$0 | 1 TB out + 10M requests free |
| **Estimated total** | **~$90/mo** | Within $150 free credit |

**Habit:** Destroy EKS when not actively working. Develop and test manifests on minikube
locally (completely free). Only spin up EKS for integration testing and screenshots.

---

## Documentation & Learning Path

The [`docs/`](docs/) folder contains 11 numbered guides walking through every phase with
concepts, code, step-by-step instructions, and verification steps. Start at the roadmap:

| Phase | Topic | Doc |
|---|---|---|
| 0 | Setup, Docker Compose, minikube basics | [00-roadmap.md](docs/00-roadmap.md), [01-local-setup.md](docs/01-local-setup.md) |
| 1 | Microservices split — 4 independent services | [02-microservices-split.md](docs/02-microservices-split.md) |
| 2 | Kubernetes manifests — Deployment, Service, Ingress | [03-k8s-manifests.md](docs/03-k8s-manifests.md) |
| 3 | Helm charts — packaging, values, dev/prod overlays | [04-helm-charts.md](docs/04-helm-charts.md) |
| 4 | EKS cluster with Terraform | [05-eks-terraform.md](docs/05-eks-terraform.md) |
| 5 | CI/CD — per-service GitHub Actions pipelines | [06-cicd.md](docs/06-cicd.md) |
| 6 | IRSA + External Secrets Operator | [07-secrets.md](docs/07-secrets.md) |
| 7 | HPA — horizontal pod autoscaling | [08-hpa.md](docs/08-hpa.md) |
| 8 | Prometheus + Grafana + Loki | [09-observability.md](docs/09-observability.md) |
| 9 | Multi-environment (dev/prod namespaces) | [10-multi-env.md](docs/10-multi-env.md) |

---

## Related

- **[cloudcare](../cloud-care)** — v1: monolithic FastAPI on EC2/ASG — the foundation this builds on.
- [AWS EKS documentation](https://docs.aws.amazon.com/eks/)
- [Kubernetes documentation](https://kubernetes.io/docs/)
- [Helm documentation](https://helm.sh/docs/)

---

*Built as a portfolio project demonstrating AWS DevOps and SRE engineering practices.
The application logic is intentionally minimal — the infrastructure, pipelines, and
operational practices are the deliverable.*
