# CloudCare-K8s — Project Overview

> **The evolution of CloudCare.**  
> Same hospital management application. Migrated from a monolithic EC2/ASG deployment to a
> microservices architecture orchestrated on Kubernetes — the way modern engineering teams
> actually run production workloads.

---

## Table of Contents

1. [What This Project Is](#1-what-this-project-is)
2. [How It Relates to CloudCare v1](#2-how-it-relates-to-cloudcare-v1)
3. [Architecture at a Glance](#3-architecture-at-a-glance)
4. [Microservices Breakdown](#4-microservices-breakdown)
5. [Tech Stack](#5-tech-stack)
6. [Repository Structure](#6-repository-structure)
7. [Infrastructure Modules (Terraform)](#7-infrastructure-modules-terraform)
8. [CI/CD Pipeline](#8-cicd-pipeline)
9. [Observability Stack](#9-observability-stack)
10. [Database Strategy](#10-database-strategy)
11. [Networking & Security](#11-networking--security)
12. [Cost Strategy](#12-cost-strategy)
13. [Engineering Practices Demonstrated](#13-engineering-practices-demonstrated)
14. [Local Development](#14-local-development)
15. [Deploy from Scratch](#15-deploy-from-scratch)
16. [Roadmap / Learning Path](#16-roadmap--learning-path)

---

## 1. What This Project Is

CloudCare-K8s is a **DevOps and SRE showcase project** built on top of the original
CloudCare HMS. The goal is not to build a production hospital system — the goal is to
demonstrate industry-level practices around:

- Microservices decomposition and independent deployability
- Container orchestration with Kubernetes (EKS)
- Infrastructure-as-Code with Terraform
- GitOps-style CI/CD with GitHub Actions
- Production-grade observability: metrics, logs, and traces
- Security-first IAM and secrets management

**What this project is not:** a feature-rich application. The CRUD logic is intentionally
minimal. The interesting work lives in `terraform/`, `helm/`, `k8s/`, and
`.github/workflows/`.

**Region:** `ap-south-1` (Mumbai)  
**IaC:** Terraform 1.9+  
**Orchestration:** Kubernetes 1.30 on EKS  
**CI/CD:** GitHub Actions + OIDC (no stored AWS keys)  
**Observability:** Prometheus + Grafana + Loki  

---

## 2. How It Relates to CloudCare v1

| Concern | CloudCare (v1) | CloudCare-K8s (v2) |
|---|---|---|
| Deployment unit | Single FastAPI monolith | 4 independent microservices |
| Compute | EC2 Auto Scaling Group | EKS node group (t3.micro) |
| Scaling | ASG instance-refresh (~5 min) | HPA pod scale-out (~30 sec) |
| Rollout | New AMI, wait for health check | Kubernetes rolling deploy |
| Rollback | Re-push previous image | `helm rollback <service> <revision>` |
| Image tagging | `:latest` | Git SHA (`:abc1234`) — fully immutable |
| Secrets | Fetched at EC2 boot | External Secrets Operator → pod env |
| Observability | CloudWatch only | Prometheus + Grafana + Loki + CloudWatch |
| Config mgmt | Env vars baked into launch template | ConfigMaps + Secrets per namespace |
| Multi-environment | Single environment | `dev` and `prod` namespaces |
| CI/CD scope | One pipeline for whole backend | One pipeline **per service** |

**Interview narrative:**  
*"I built CloudCare on traditional AWS infrastructure to understand the fundamentals.
Then I re-platformed it onto Kubernetes to learn how modern teams actually operate
containerised workloads — independent deployments, faster rollouts, and a proper
observability stack."*

---

## 3. Architecture at a Glance

```
Users
  │
  ▼
CloudFront (HTTPS)
  ├── /             → S3 (React SPA, private via OAC)
  └── /api/*        → ALB (Ingress Controller)
                          │
                    ┌─────▼──────────────────────┐
                    │         EKS Cluster         │
                    │  ┌──────────────────────┐   │
                    │  │  patient-service     │   │
                    │  │  appointment-service │   │
                    │  │  audit-service       │   │
                    │  │  notification-service│   │
                    │  └──────────┬───────────┘   │
                    └────────────┼────────────────┘
                                 │
                    ┌────────────▼────────────────┐
                    │   RDS PostgreSQL (private)   │
                    │   patients schema            │
                    │   appointments schema        │
                    └─────────────────────────────┘

Monitoring plane (runs in cluster):
  Prometheus → scrapes all services
  Grafana    → dashboards
  Loki       → log aggregation
```

> The data tier sits in a private subnet with no public route.
> It only accepts connections from the app security group on port 5432.

---

## 4. Microservices Breakdown

Each service is an independently deployable unit with its own:
- Docker image and ECR repository
- Helm chart and Kubernetes Deployment
- GitHub Actions workflow
- PostgreSQL schema (database-per-service pattern, schema-level isolation on one RDS instance)

### patient-service
- **Owns:** `patients` PostgreSQL schema
- **Endpoints:** `GET/POST /patients`, `GET/PUT/DELETE /patients/{id}`
- **Port:** 8001
- **Tech:** Python 3.12, FastAPI

### appointment-service
- **Owns:** `appointments` PostgreSQL schema
- **Endpoints:** `GET/POST /appointments`, `GET/PUT/DELETE /appointments/{id}`
- **Port:** 8002
- **Tech:** Python 3.12, FastAPI
- **Depends on:** patient-service (internal cluster DNS call to verify patient exists)

### audit-service
- **Owns:** DynamoDB table `audit_events`
- **Endpoints:** `POST /audit` (internal only, not exposed via Ingress)
- **Port:** 8003
- **Tech:** Python 3.12, FastAPI
- **Note:** Receives audit events from other services via internal K8s Service

### notification-service
- **Owns:** Nothing persistent; calls SES
- **Endpoints:** `POST /notify` (internal only)
- **Port:** 8004
- **Tech:** Python 3.12, FastAPI
- **Note:** Replaces the Lambda contact form from v1; now runs as a pod

> **Why schema isolation, not separate RDS instances?**  
> The correct production pattern is a separate database per service.
> At free-tier scale, separate RDS instances would cost ~$50/month each.
> Schema-level isolation demonstrates the ownership boundary (each service
> only connects to its own schema with its own DB user) while keeping costs at $0.
> In a real environment, each schema becomes its own RDS instance.

---

## 5. Tech Stack

### Cloud & Orchestration
| Tool | Role |
|---|---|
| AWS EKS | Managed Kubernetes control plane |
| Terraform 1.9+ | All infrastructure declared as code |
| Helm 3 | Package manager for K8s manifests |
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
| External Secrets Operator | Syncs Secrets Manager → K8s Secrets automatically |

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

### Application
| Tool | Role |
|---|---|
| FastAPI (Python 3.12) | All four backend microservices |
| React 18 + Vite | Single-page frontend, unchanged from v1 |

---

## 6. Repository Structure

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
├── frontend/                          ← React 18 + Vite (unchanged from v1)
│   ├── src/
│   ├── index.html
│   └── package.json
│
├── terraform/                         ← 3 stacks, each with own state key
│   ├── bootstrap/                     ← S3 state bucket + DynamoDB lock (run once)
│   ├── eks/                           ← VPC, EKS cluster, node group, IAM, ECR repos
│   └── platform/                      ← RDS, Secrets Manager, ALB Ingress Controller,
│                                          External Secrets Operator, CloudFront, S3
│
├── helm/                              ← one Helm chart per service
│   ├── patient-service/
│   │   ├── Chart.yaml
│   │   ├── values.yaml                ← base values
│   │   ├── values-dev.yaml            ← dev overrides
│   │   ├── values-prod.yaml           ← prod overrides
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       └── externalsecret.yaml
│   ├── appointment-service/
│   ├── audit-service/
│   └── notification-service/
│
├── k8s/                               ← raw manifests (Kustomize)
│   ├── base/                          ← shared resources (namespaces, RBAC, Ingress)
│   └── overlays/
│       ├── dev/                       ← dev-specific patches
│       └── prod/                      ← prod-specific patches
│
├── monitoring/
│   ├── prometheus/                    ← custom scrape configs and alerting rules
│   ├── grafana/
│   │   └── dashboards/                ← dashboard JSON exports
│   └── loki/                          ← Promtail config
│
├── .github/
│   └── workflows/
│       ├── patient-service.yml        ← test → build → push → helm upgrade
│       ├── appointment-service.yml
│       ├── audit-service.yml
│       ├── notification-service.yml
│       ├── frontend.yml               ← build → s3 sync → CF invalidate
│       └── terraform.yml             ← plan on PR, apply on merge to main
│
└── docs/                              ← numbered docs, one per phase
    ├── 00-overview.md                 ← this file
    ├── 01-eks-cluster.md
    ├── 02-microservices-split.md
    ├── 03-helm-charts.md
    ├── 04-cicd-pipelines.md
    ├── 05-observability.md
    └── 06-multi-env.md
```

---

## 7. Infrastructure Modules (Terraform)

Each stack has its own remote state key. Stacks read each other via
`terraform_remote_state` — never by redeclaring resources.

| Stack | State key | Reads from | Free-tier risk |
|---|---|---|---|
| bootstrap | `bootstrap/terraform.tfstate` | — | ✅ cents/month |
| eks | `eks/terraform.tfstate` | bootstrap | ⚠️ EKS control plane ~$73/mo |
| platform | `platform/terraform.tfstate` | eks | ⚠️ RDS hours |

### eks stack provisions:
- VPC with public / private-app / private-DB subnets across 2 AZs
- EKS cluster (Kubernetes 1.30)
- Managed node group: t3.micro × 2 (free-tier eligible)
- NAT instance (not NAT Gateway — saves ~$32/month)
- OIDC provider for GitHub Actions and for IRSA (IAM Roles for Service Accounts)
- One ECR repository per microservice
- IAM roles scoped per service (least-privilege)

### platform stack provisions:
- RDS PostgreSQL 16 db.t3.micro (single-AZ, free-tier eligible)
- Secrets Manager secret for DB credentials
- AWS ALB Ingress Controller (Helm release via Terraform)
- External Secrets Operator (Helm release via Terraform)
- S3 bucket for React frontend
- CloudFront distribution with OAC

---

## 8. CI/CD Pipeline

**Principle: each service is deployed independently.** Changing patient-service
triggers only patient-service's pipeline. The other three services keep running.

### Per-service pipeline (e.g. `patient-service.yml`)

```
Trigger: push to main, changes in services/patient-service/**
         OR pull_request touching the same path

Jobs:

1. test
   └── pytest services/patient-service/tests/

2. build-push  (needs: test)
   ├── Authenticate to AWS via OIDC (no stored keys)
   ├── docker build -t $ECR_REPO:${{ github.sha }} .
   └── docker push $ECR_REPO:${{ github.sha }}

3. deploy-dev  (needs: build-push, on push to main)
   └── helm upgrade patient-service ./helm/patient-service
         --set image.tag=${{ github.sha }}
         -f helm/patient-service/values-dev.yaml
         --namespace dev

4. deploy-prod  (needs: deploy-dev)
   ├── environment: production          ← manual approval gate in GitHub
   └── helm upgrade patient-service ./helm/patient-service
         --set image.tag=${{ github.sha }}
         -f helm/patient-service/values-prod.yaml
         --namespace prod
```

### Key upgrades over CloudCare v1

| Practice | v1 | v2 |
|---|---|---|
| Image tag | `:latest` | `:abc1234` (git SHA) — immutable, traceable |
| Tests | None | pytest runs before every build |
| Rollback | Manual image re-push | `helm rollback patient-service 2` |
| Environments | One | dev (auto) → prod (manual approval) |
| Deploy time | ~5 min (instance-refresh) | ~30 sec (rolling pod update) |

### AWS authentication (OIDC — no stored keys)

Same pattern as CloudCare v1 — GitHub OIDC federation:

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cloudcare-k8s-deploy
    aws-region: ap-south-1
```

The IAM role's trust policy pins the `sub` claim to
`repo:your-username/cloudcare-k8s:ref:refs/heads/main` — so a fork or a
feature branch cannot assume this role.

---

## 9. Observability Stack

### Three pillars

| Pillar | Tool | What it captures |
|---|---|---|
| Metrics | Prometheus + Grafana | Request rate, error rate, latency (RED), pod CPU/memory, RDS metrics |
| Logs | Loki + Promtail | Structured JSON logs from every pod, aggregated and queryable |
| Traces | AWS X-Ray | Distributed traces across audit-service and notification-service |

All three are deployed into the `monitoring` namespace via Helm charts
(kube-prometheus-stack, Loki stack).

### Key Grafana dashboards

- **Service overview** — RED metrics (Rate, Error, Duration) per service
- **Kubernetes cluster** — node CPU/memory, pod restarts, HPA activity
- **RDS** — connections, CPU, storage free
- **ALB** — request count, 5xx rate, target health

### Alerting rules (Prometheus AlertManager)

| Alert | Threshold | Action |
|---|---|---|
| HighErrorRate | >5% 5xx over 5 min per service | Slack + email via SNS |
| PodCrashLooping | >2 restarts in 5 min | Page immediately |
| HPAMaxReplicas | HPA at max for >10 min | Scale-up investigation |
| RDSStorageLow | <2 GB free | Lead time before writes fail |
| RDSConnectionsHigh | >80 connections | db.t3.micro caps near 100 |

### Why Prometheus/Grafana over CloudWatch alone?

CloudWatch is AWS-native and excellent for AWS resources (RDS, ALB, EKS control
plane). Prometheus/Grafana is the industry standard for application-level
observability inside Kubernetes — scraping custom metrics from your pods,
visualising per-service SLIs, and alerting on business-relevant signals.
This project uses both: CloudWatch for the AWS layer, Prometheus/Grafana for
the application layer.

---

## 10. Database Strategy

### Schema-per-service isolation

```
RDS PostgreSQL instance (db.t3.micro, single-AZ)
│
├── Database: cloudcare
│   ├── Schema: patients         ← owned by patient_svc DB user
│   └── Schema: appointments     ← owned by appt_svc DB user
│
└── DynamoDB table: audit_events ← owned by audit-service via IRSA
```

Each service connects with its own PostgreSQL user that has `USAGE` and
`CREATE` only on its own schema — it cannot read or write another service's tables.
Credentials are stored in Secrets Manager and synced into the pod's environment
by the External Secrets Operator.

### Production note (documented in README)

> In a production environment, each service would have its own RDS instance
> for full blast-radius isolation. Schema-level isolation here demonstrates
> the ownership boundary while staying within the AWS Free Tier.
> The migration path from schema isolation to instance isolation is:
> dump schema → restore to new RDS → update Secrets Manager → redeploy service.

---

## 11. Networking & Security

### VPC layout (same as CloudCare v1)

| CIDR | Tier | Public? | Purpose |
|---|---|---|---|
| 10.0.0.0/24, 10.0.1.0/24 | Public | ✅ | ALB, NAT instance |
| 10.0.10.0/24, 10.0.11.0/24 | App (private) | ❌ | EKS worker nodes |
| 10.0.20.0/24, 10.0.21.0/24 | DB (private) | ❌ | RDS PostgreSQL |

### Security group chain

```
ALB SG     → accepts 80, 443 from 0.0.0.0/0
Node SG    → accepts traffic from ALB SG only
RDS SG     → accepts 5432 from Node SG only
```

### IAM: IRSA (IAM Roles for Service Accounts)

Each Kubernetes service account is annotated with an IAM role ARN. EKS
automatically exchanges the pod's projected service account token for
short-lived AWS credentials via OIDC. No node-level instance profiles —
each pod only gets the permissions it needs:

| Service account | IAM permissions |
|---|---|
| patient-service | `secretsmanager:GetSecretValue` on patient DB secret ARN only |
| appointment-service | `secretsmanager:GetSecretValue` on appointment DB secret ARN only |
| audit-service | `dynamodb:PutItem` on audit table ARN only |
| notification-service | `ses:SendEmail` conditioned on `ses:FromAddress` |
| external-secrets | `secretsmanager:GetSecretValue` on all cloudcare/* secrets |

### Additional hardening

- IMDSv2 enforced on all worker nodes (`http_tokens = required`)
- S3 bucket policy: only CloudFront distribution ARN can read objects (OAC)
- EKS API server: private endpoint only (no public K8s API)
- Kubernetes RBAC: each service has its own ServiceAccount, no shared default SA

---

## 12. Cost Strategy

Designed to stay within or very close to the AWS Free Tier.

| Resource | Est. monthly cost | Notes |
|---|---|---|
| EKS control plane | ~$73 | No free tier — biggest cost |
| 2× t3.micro worker nodes | ~$0 | 750 hrs/mo free tier |
| RDS db.t3.micro | ~$0 | 750 hrs/mo free tier |
| ALB | ~$16 | Fixed hourly + LCU |
| NAT instance (t3.micro) | ~$0 | Free tier; saves ~$32 vs NAT GW |
| CloudFront | ~$0 | 1 TB out + 10M requests free |
| ECR (4 repos) | ~$0 | 500 MB free |
| **Estimated total** | **~$90/mo** | Within $150 free credit |

### Habits

- Destroy EKS when not actively working: `terraform destroy` in `terraform/eks/`
- Develop and test manifests on **minikube locally** — completely free
- Only spin up EKS for integration testing and final screenshots
- `bootstrap/` and `platform/` (RDS) left running: costs ~$0 in free tier

---

## 13. Engineering Practices Demonstrated

| # | Practice | Where to find it |
|---|---|---|
| 1 | Microservices decomposition — logical service boundaries, independent deployability | `services/`, `helm/`, `.github/workflows/` |
| 2 | Kubernetes-native scaling — HPA replaces ASG instance-refresh | `helm/*/templates/hpa.yaml` |
| 3 | Immutable image tags — git SHA, not latest | every `*-service.yml` workflow |
| 4 | GitOps deployment — Helm chart is source of truth, CI applies it | `helm/`, workflows |
| 5 | IRSA least-privilege — pod-level AWS permissions, not node-level | `terraform/eks/irsa.tf` |
| 6 | External Secrets Operator — secrets live in Secrets Manager, not in Git | `helm/*/templates/externalsecret.yaml` |
| 7 | Multi-environment with manual approval gate | `deploy-prod` job, GitHub environments |
| 8 | Prometheus/Grafana/Loki observability — three-pillar stack | `monitoring/` |
| 9 | Keyless CI/CD — OIDC, no stored AWS keys, sub claim pinned | `terraform/eks/oidc.tf` |
| 10 | Database-per-service pattern — schema isolation with documented upgrade path | `docs/02-microservices-split.md` |

---

## 14. Local Development

### Prerequisites

- Docker Desktop (includes kubectl)
- minikube or kind
- Helm 3
- Terraform >= 1.9
- Node.js 20+
- Python 3.12

### Run all services locally with Docker Compose

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
# Start cluster
minikube start --cpus=2 --memory=4g

# Deploy one service
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev --create-namespace

# Watch pods come up
kubectl get pods -n dev -w

# Port-forward to test
kubectl port-forward svc/patient-service 8001:8001 -n dev
curl http://localhost:8001/patients
```

### Run the frontend

```bash
cd frontend
npm install
npm run dev
# Vite dev server → http://localhost:5173
```

Point the frontend at a specific backend:

```bash
# .env.local
VITE_PATIENT_API=http://localhost:8001
VITE_APPOINTMENT_API=http://localhost:8002
```

---

## 15. Deploy from Scratch

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
terraform init
terraform apply
# ⚠️  EKS control plane starts billing (~$2.40/day) from this point.
# Destroy when done: terraform destroy

# Configure kubectl
aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1
kubectl get nodes  # should show 2 t3.micro nodes
```

### Phase 2 — Provision platform resources

```bash
cd terraform/platform
terraform init
terraform apply
# Provisions: RDS, Secrets Manager, ALB Ingress Controller,
#             External Secrets Operator, S3, CloudFront
```

### Phase 3 — Push images and deploy services

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

### Phase 5 — Verify

```bash
CF=$(cd terraform/platform && terraform output -raw cloudfront_domain_name)
echo "Open https://$CF"

curl "https://$CF/api/patients"
curl "https://$CF/api/appointments"
```

### Teardown (return to ~$0)

```bash
# Remove all K8s resources first
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod
done

# Destroy in reverse dependency order
for stack in platform eks bootstrap; do
  ( cd terraform/$stack && terraform destroy -auto-approve )
done
```

---

## 16. Roadmap / Learning Path

This project is built incrementally. Each phase has a dedicated doc in `docs/`.

| Phase | Topic | Doc | Status |
|---|---|---|---|
| 0 | Project setup, local Docker Compose, minikube basics | `01-local-setup.md` | 🔲 |
| 1 | Microservices split — patient + appointment services | `02-microservices-split.md` | 🔲 |
| 2 | Kubernetes manifests — Deployment, Service, Ingress | `03-k8s-manifests.md` | 🔲 |
| 3 | Helm charts — packaging, values, dev/prod overlays | `04-helm-charts.md` | 🔲 |
| 4 | EKS cluster with Terraform | `05-eks-terraform.md` | 🔲 |
| 5 | CI/CD — per-service GitHub Actions pipelines | `06-cicd.md` | 🔲 |
| 6 | IRSA + External Secrets Operator | `07-secrets.md` | 🔲 |
| 7 | HPA — horizontal pod autoscaling | `08-hpa.md` | 🔲 |
| 8 | Prometheus + Grafana + Loki | `09-observability.md` | 🔲 |
| 9 | Multi-environment (dev/prod namespaces) | `10-multi-env.md` | 🔲 |

---

## Related

- **[cloudcare](https://github.com/your-username/cloudcare)** — v1: monolithic FastAPI
  on EC2/ASG, the foundation this project builds on.
- AWS EKS documentation: https://docs.aws.amazon.com/eks/
- Kubernetes documentation: https://kubernetes.io/docs/
- Helm documentation: https://helm.sh/docs/

---

*Built as a portfolio project demonstrating AWS DevOps and SRE engineering practices.
The application logic is intentionally minimal — the infrastructure, pipelines, and
operational practices are the deliverable.*
