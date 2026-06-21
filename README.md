# CloudCare-K8s — AWS DevOps Showcase v2

> **The evolution of CloudCare.**
> Same hospital management system. Migrated from a monolithic EC2/ASG deployment
> to a **microservices architecture orchestrated on Kubernetes** — the way modern
> engineering teams actually run production workloads.

**Region** `ap-south-1` (Mumbai) · **IaC** Terraform 1.10+ · **Orchestration** Kubernetes 1.30 on EKS ·
**Backend** Python 3.12 + FastAPI (4 microservices) · **CI/CD** GitHub Actions + OIDC ·
**Observability** Prometheus + Grafana + Loki

---

## Scope — what this repo is and isn't

This project demonstrates **Kubernetes, microservices operations, and cloud-native SRE** on AWS.
The hospital management app (patients, appointments) is intentionally minimal CRUD — it exists to
give the infrastructure something real to host and operate.

> **No frontend in this repo.**
> The React frontend and its CDN infrastructure (S3 + CloudFront + GitHub Actions deploy workflow)
> live entirely in the companion **[cloud-care](../cloud-care)** repository (v1).
> This repo is 100% backend: microservices, Kubernetes, Helm, EKS, and CI/CD for those services.
>
> In a real production setup the same React SPA from v1 would point its `/api/*` calls at
> the ALB Ingress in this cluster — the frontend itself needs no changes. That's why we
> don't duplicate it here.
>
> To evaluate this project, read the Terraform stacks, Helm charts, and GitHub Actions workflows.

---

## How v2 Differs from CloudCare v1

| Concern | CloudCare v1 (EC2/ASG) | CloudCare-K8s v2 (EKS) |
|---|---|---|
| Deployment unit | Single FastAPI monolith | 4 independent microservices |
| Compute | EC2 Auto Scaling Group | EKS node group (t3.small × 3) |
| Scaling | ASG instance-refresh (~5 min) | HPA pod scale-out (~30 sec) |
| Rollout strategy | New AMI, wait for health check | Kubernetes rolling deploy |
| Rollback | Re-push previous image | `helm rollback <service> <revision>` |
| Image tagging | `:latest` | Git SHA (`:abc1234`) — immutable |
| Secrets | Fetched at EC2 boot | K8s Secrets created from Secrets Manager |
| Observability | CloudWatch only | Prometheus + Grafana + Loki + AlertManager |
| Config management | Env vars baked into launch template | ConfigMaps + Secrets per namespace |
| Multi-environment | Single environment | `dev` and `prod` namespaces |
| CI/CD scope | One pipeline for the whole backend | One pipeline **per service** + one for Terraform |

---

## Tech Stack

<table>
  <tr>
    <td width="33%" valign="top">
      <h4>Cloud &amp; Orchestration</h4>
      <p>
        <img src="https://img.shields.io/badge/AWS-232F3E?style=for-the-badge&logo=amazonwebservices&logoColor=white" alt="AWS"/>
        <img src="https://img.shields.io/badge/Kubernetes%201.30-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="Kubernetes"/>
        <img src="https://img.shields.io/badge/Amazon%20EKS-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white" alt="EKS"/>
        <img src="https://img.shields.io/badge/Terraform%201.10-7B42BC?style=for-the-badge&logo=terraform&logoColor=white" alt="Terraform"/>
        <img src="https://img.shields.io/badge/Helm%203-0F1689?style=for-the-badge&logo=helm&logoColor=white" alt="Helm 3"/>
      </p>
      <sub>EKS managed control plane; Terraform declares every resource; Helm packages per-service charts with dev/prod value overlays.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Compute &amp; Networking</h4>
      <p>
        <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker"/>
        <img src="https://img.shields.io/badge/ECR-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white" alt="ECR"/>
        <img src="https://img.shields.io/badge/ALB%20Ingress-FF9900?style=for-the-badge" alt="ALB Ingress"/>
        <img src="https://img.shields.io/badge/VPC-232F3E?style=for-the-badge&logo=amazonaws&logoColor=white" alt="VPC"/>
      </p>
      <sub>EKS t3.small × 3 node group in public subnets (direct IGW access); one ECR repo per service; AWS ALB Ingress Controller routes external traffic via path-based rules.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Edge (v1 — cloud-care repo)</h4>
      <p>
        <img src="https://img.shields.io/badge/CloudFront-8C4FFF?style=for-the-badge" alt="CloudFront"/>
        <img src="https://img.shields.io/badge/S3%20%28static%29-569A31?style=for-the-badge&logo=amazons3&logoColor=white" alt="S3 static"/>
      </p>
      <sub>Defined in the companion cloud-care (v1) repo — not in this repo.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Data</h4>
      <p>
        <img src="https://img.shields.io/badge/RDS%20PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="RDS PostgreSQL"/>
        <img src="https://img.shields.io/badge/DynamoDB-4053D6?style=for-the-badge&logo=amazondynamodb&logoColor=white" alt="DynamoDB"/>
        <img src="https://img.shields.io/badge/Secrets%20Manager-DD344C?style=for-the-badge" alt="Secrets Manager"/>
      </p>
      <sub>Schema-per-service on shared RDS (patients schema, appointments schema); audit events in DynamoDB; Secrets Manager stores DB credentials synced to K8s Secrets at deploy time.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Observability</h4>
      <p>
        <img src="https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white" alt="Prometheus"/>
        <img src="https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white" alt="Grafana"/>
        <img src="https://img.shields.io/badge/Loki-F46800?style=for-the-badge" alt="Loki"/>
        <img src="https://img.shields.io/badge/AlertManager-E6522C?style=for-the-badge" alt="AlertManager"/>
      </p>
      <sub>Prometheus scrapes /metrics from all 4 services every 15s; Grafana pre-built Kubernetes dashboards + custom PromQL; Loki aggregates logs via Promtail DaemonSet; AlertManager fires on CrashLoop, high error rate, and high latency.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Identity &amp; CI/CD</h4>
      <p>
        <img src="https://img.shields.io/badge/IAM%20%2B%20IRSA-DD344C?style=for-the-badge" alt="IAM + IRSA"/>
        <img src="https://img.shields.io/badge/GitHub%20Actions-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions"/>
      </p>
      <sub>IRSA gives each pod its own AWS identity — no node-level credentials; keyless CI via OIDC; one pipeline per service + one Terraform pipeline; concurrency groups prevent Helm lock conflicts.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Application</h4>
      <p>
        <img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI"/>
      </p>
      <sub>4 Python 3.12 FastAPI microservices — each exposes /metrics endpoint via prometheus-fastapi-instrumentator for Prometheus scraping.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Local Dev</h4>
      <p>
        <img src="https://img.shields.io/badge/Docker%20Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker Compose"/>
      </p>
      <sub>Full stack runs locally via Docker Compose with DynamoDB Local and PostgreSQL — no cloud costs during development.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Messaging</h4>
      <p>
        <img src="https://img.shields.io/badge/Amazon%20SES-DD344C?style=for-the-badge" alt="SES"/>
      </p>
      <sub>notification-service calls SES for transactional email via IRSA — no stored AWS credentials in the pod.</sub>
    </td>
  </tr>
</table>

---

## Engineering Practices Demonstrated

| # | Practice | Where to find it |
|---|---|---|
| 1 | **Microservices decomposition** — logical boundaries, independent deployability | `services/`, `helm/`, `.github/workflows/` |
| 2 | **Kubernetes-native scaling** — HPA replaces ASG instance-refresh | `helm/*/templates/hpa.yaml` |
| 3 | **Immutable image tags** — git SHA, not `:latest` | every `*-service.yml` workflow |
| 4 | **GitOps deployment** — Helm chart is source of truth, CI applies it | `helm/`, workflows |
| 5 | **IRSA least-privilege** — pod-level AWS identity, not node-level credentials | `terraform/platform/irsa.tf` |
| 6 | **K8s Secrets from Secrets Manager** — credentials never in Git or Helm values | `k8s/` + deploy scripts |
| 7 | **Multi-environment** — `dev` vs `prod` namespace via Helm value overlays | `helm/*/values-prod.yaml` |
| 8 | **Three-pillar observability** — metrics (Prometheus), logs (Loki), dashboards (Grafana), alerts (AlertManager) | `monitoring/` |
| 9 | **Keyless CI/CD** — GitHub OIDC, no stored AWS keys, `sub` claim pinned to repo | `terraform/eks/oidc.tf` |
| 10 | **Database-per-service pattern** — schema isolation, service-specific DB users | `docs/02-microservices-split.md` |
| 11 | **Pipeline concurrency control** — `concurrency` groups prevent simultaneous Helm upgrades locking the same release | `.github/workflows/deploy-*.yml` |

---

## Table of Contents

- [Architecture at a glance](#architecture-at-a-glance)
- [Architecture diagram](#architecture-diagram)
- [Microservices breakdown](#microservices-breakdown)
- [Request flow](#request-flow)
- [Network topology](#network-topology)
- [Security architecture](#security-architecture)
- [Kubernetes resource model](#kubernetes-resource-model)
- [Data model](#data-model)
- [Infrastructure modules](#infrastructure-modules)
- [CI/CD pipeline](#cicd-pipeline)
- [Observability](#observability)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick start — deploy from scratch](#quick-start--deploy-from-scratch)
- [Local development](#local-development)
- [Cost](#cost)
- [Teardown](#teardown)
- [Known issues & resolutions](#known-issues--resolutions)
- [Documentation & learning path](#documentation--learning-path)

---

## Architecture at a glance

Users hit the **AWS ALB** (provisioned by the ALB Ingress Controller). Path-based rules route
requests to the appropriate microservice **pods** inside the **EKS cluster**.

Four microservices run in the `prod` namespace: `patient-service`, `appointment-service`,
`audit-service`, and `notification-service` — each independently deployable with its own
ECR repo, Helm chart, and GitHub Actions pipeline. Services talk to a private
**RDS PostgreSQL** instance using schema-per-service isolation. DB credentials are stored in
**Secrets Manager** and pulled into **Kubernetes Secrets** at deploy time.

The audit-service writes to **DynamoDB** via IRSA (no stored AWS keys). The notification-service
sends email via **SES**, also via IRSA. The `monitoring` namespace runs Prometheus, Grafana,
Loki, and AlertManager — all installed via Helm.

---

## Architecture diagram

```mermaid
flowchart TB
    User([Users / API clients])

    subgraph VPC["VPC 10.0.0.0/16 — ap-south-1"]
        IGW{{Internet Gateway}}

        subgraph Pub["Public subnets 10.0.0.0/24, 10.0.1.0/24 (AZ-a, AZ-b)"]
            ALB["AWS ALB\n(ALB Ingress Controller)"]
            Nodes["EKS Worker Nodes\nt3.small × 3\n(EKS pods run here)"]
        end

        subgraph DBT["Private DB subnets 10.0.20.0/24, 10.0.21.0/24 (AZ-a, AZ-b)"]
            RDS[("RDS PostgreSQL 16\nschema: patients\nschema: appointments")]
        end
    end

    subgraph EKS["EKS Cluster"]
        subgraph prod["prod namespace"]
            PS["patient-service :8001"]
            APPS["appointment-service :8002"]
            AUS["audit-service :8003"]
            NS2["notification-service :8004"]
        end
        subgraph monitoring["monitoring namespace"]
            PROM["Prometheus"]
            GRAF["Grafana"]
            LOKI["Loki + Promtail"]
            AM["AlertManager"]
        end
    end

    subgraph AWSsvc["AWS Services"]
        ECR[("ECR\n4 Docker repos")]
        SM[("Secrets Manager\nDB credentials")]
        DDB[("DynamoDB\naudit_events")]
        SES["Amazon SES\nemail"]
        CW["CloudWatch"]
    end

    User -- HTTP --> ALB
    IGW --- ALB
    IGW --- Nodes
    ALB --> PS & APPS & AUS & NS2
    PS & APPS --> RDS
    AUS -- "IRSA" --> DDB
    NS2 -- "IRSA" --> SES
    SM -. "pulled at deploy" .-> PS & APPS
    PS & APPS & AUS & NS2 -. "pull image" .-> ECR
    PROM -. "scrape /metrics" .-> PS & APPS & AUS & NS2
    LOKI -. "collect logs" .-> PS & APPS & AUS & NS2
    CW -. "AWS metrics" .-> RDS & ALB
```

---

## Microservices Breakdown

Each service is independently deployable with its own Docker image, ECR repo, Helm chart,
GitHub Actions workflow, and database schema.

| Service | Port | Routes | Stores data in |
|---|---|---|---|
| `patient-service` | 8001 | `GET/POST /patients`, `GET/PUT/DELETE /patients/{id}` | RDS — `patients` schema |
| `appointment-service` | 8002 | `GET/POST /appointments`, `GET/PUT/DELETE /appointments/{id}` | RDS — `appointments` schema |
| `audit-service` | 8003 | `POST /audit`, `GET /audit` | DynamoDB — `audit_events` table |
| `notification-service` | 8004 | `POST /notify` | — (calls SES, no persistence) |

All 4 services expose `/metrics` (via `prometheus-fastapi-instrumentator`) and `/health`.

---

## Request flow

```mermaid
sequenceDiagram
    actor User
    participant ALB as ALB Ingress
    participant PS as patient-service
    participant AS as appointment-service
    participant AUD as audit-service
    participant RDS as RDS PostgreSQL
    participant DDB as DynamoDB

    rect rgb(238,255,238)
    Note over User,DDB: Create a patient
    User->>ALB: POST /patients { full_name, date_of_birth, phone }
    ALB->>PS: route → patient-service :8001
    PS->>RDS: INSERT INTO patients.patients
    RDS-->>PS: row with id
    PS--)AUD: POST /audit (background task — fire and forget)
    AUD->>DDB: PutItem { entity_type: patient, action: created }
    PS-->>User: 201 Created { id: 1, ... }
    end

    rect rgb(245,238,255)
    Note over User,DDB: Book an appointment
    User->>ALB: POST /appointments { patient_id: 1, scheduled_for, reason }
    ALB->>AS: route → appointment-service :8002
    AS->>RDS: INSERT INTO appointments.appointments
    RDS-->>AS: row
    AS--)AUD: POST /audit (background task)
    AUD->>DDB: PutItem { entity_type: appointment, action: created }
    AS-->>User: 201 Created { id: 2, ... }
    end
```

---

## Network topology

Six subnets across two AZs, three tiers. **EKS nodes are in public subnets** — they get public
IPs and reach the internet directly through the IGW (no NAT needed).

```mermaid
flowchart TB
    Internet((Internet))
    IGW{{Internet Gateway}}

    subgraph VPC["VPC — 10.0.0.0/16"]

        subgraph AZa["Availability Zone ap-south-1a"]
            PubA["Public subnet\n10.0.0.0/24\n(ALB + EKS nodes)"]
            DbA["Private DB subnet\n10.0.20.0/24\n(RDS primary)"]
        end

        subgraph AZb["Availability Zone ap-south-1b"]
            PubB["Public subnet\n10.0.1.0/24\n(ALB + EKS nodes)"]
            DbB["Private DB subnet\n10.0.21.0/24\n(RDS standby)"]
        end

        RTpub["Public route table\n0.0.0.0/0 → IGW"]
        RTpriv["Private route table\n(no internet route — DB only)"]
    end

    Internet --- IGW
    IGW --- PubA & PubB
    PubA & PubB -.assoc.-> RTpub
    DbA & DbB  -.assoc.-> RTpriv
```

| CIDR | Tier | Public? | Purpose |
|------|------|---------|---------|
| `10.0.0.0/24`, `10.0.1.0/24` | Public | ✅ (→ IGW) | ALB Ingress + EKS worker nodes |
| `10.0.10.0/24`, `10.0.11.0/24` | App (private) | ❌ (unused) | Reserved |
| `10.0.20.0/24`, `10.0.21.0/24` | DB (private) | ❌ (local only) | RDS PostgreSQL |

> **Why nodes are in public subnets:** Originally placed in private subnets with a NAT instance.
> Nodes failed to join the cluster after 33+ minutes (NodeCreationFailure) because the NAT
> instance couldn't reliably route EKS API and ECR traffic. Moving nodes to public subnets
> (direct IGW) resolved the issue. Security is maintained via Security Groups — no SSH ports
> open, pod traffic controlled by EKS-managed security groups.

---

## Security architecture

```mermaid
flowchart LR
    I([Internet]) -- ":80" --> ALB["alb-sg"]
    ALB -- ":8001–8004" --> EKS["eks-node-sg"]
    EKS -- ":5432" --> D["db-sg\n10.0.0.0/16 only"]

    style ALB fill:#dbeafe,stroke:#1d4ed8,color:#000
    style EKS fill:#fef3c7,stroke:#b45309,color:#000
    style D   fill:#fee2e2,stroke:#b91c1c,color:#000
```

- **No long-lived AWS keys in GitHub** — CI authenticates via GitHub OIDC → `sts:AssumeRoleWithWebIdentity` → 15-min temp credentials per job
- **IRSA per pod** — audit-service and notification-service each have their own IAM role
- **IMDSv2 enforced** on all EKS nodes (`http_tokens = "required"`) to block SSRF-based credential theft
- **EKS access entries** — GitHub Actions IAM role granted cluster-admin via `aws_eks_access_entry` (API mode), not via aws-auth ConfigMap
- **RDS not publicly accessible** — `publicly_accessible = false`, SG allows only VPC traffic on port 5432
- **Secrets never in Git** — DB credentials live in Secrets Manager, pulled into K8s Secrets at deploy time

---

## Kubernetes resource model

```mermaid
flowchart TB
    subgraph NS["Namespace: prod"]
        subgraph SVC["patient-service"]
            D1["Deployment (replicas: 2)"]
            SVC1["Service ClusterIP :8001"]
            HPA1["HPA — target CPU 70%, max 6 pods"]
            SA1["ServiceAccount\n+ IRSA annotation (audit/notif only)"]
            SEC1["K8s Secret\npatient-service-db-secret\n(DATABASE_URL)"]
        end
        ING["Ingress (ALB)\n/patients → patient-service\n/appointments → appointment-service\n/audit → audit-service\n/notify → notification-service"]
    end

    subgraph MON["Namespace: monitoring"]
        PROM["kube-prometheus-stack\n(Prometheus + Grafana + AlertManager)"]
        LOKI2["loki-stack\n(Loki + Promtail DaemonSet)"]
        RULES["PrometheusRule\ncloudcare-alerts\n(CrashLoop, HighErrorRate, HighLatency)"]
    end

    ING --> SVC1 --> D1
    HPA1 -. scales .-> D1
    SEC1 -. env var .-> D1
    SA1 -. pod identity .-> D1
    PROM -. scrapes /metrics .-> D1
    LOKI2 -. collects logs .-> D1
```

---

## Data model

```mermaid
erDiagram
    PATIENTS ||--o{ APPOINTMENTS : "has many"

    PATIENTS {
        int      id           PK
        string   full_name
        date     date_of_birth
        string   phone
        datetime created_at
    }

    APPOINTMENTS {
        int      id           PK
        int      patient_id   FK
        datetime scheduled_for
        string   reason
        string   status
        datetime created_at
    }

    AUDIT_EVENTS {
        string   event_id    PK
        string   ts
        string   entity_type
        string   entity_id
        string   action
        string   actor
    }
```

`PATIENTS` and `APPOINTMENTS` live in **RDS PostgreSQL** under schema-per-service isolation.
`AUDIT_EVENTS` lives in **DynamoDB** — high-volume, write-heavy, no joins needed.

---

## Infrastructure modules

Three Terraform stacks, each with its own state key in S3:

```
s3://cloudcare-k8s-tfstate-<account>/
  bootstrap/terraform.tfstate   ← local state only (run once)
  eks/terraform.tfstate          ← VPC, EKS, ECR, OIDC, EKS access entries
  platform/terraform.tfstate     ← RDS, Secrets Manager, ALB controller, IRSA, DynamoDB
```

```mermaid
flowchart TB
    BS["bootstrap\nS3 state bucket (run once, costs cents)"]
    EKS["eks\nVPC · subnets · IGW\nEKS cluster · t3.small × 3 node group\n4× ECR repos · OIDC provider\nGitHub OIDC + deploy IAM role\nEKS access entry for CI role"]
    PLAT["platform\nRDS PostgreSQL · Secrets Manager\nALB Ingress Controller (Helm)\nMetrics Server (Helm)\nDynamoDB audit_events\nIRSA roles (audit + notification)"]

    BS -.->|hosts state for| EKS & PLAT
    EKS -->|remote_state outputs| PLAT
```

| Stack | Apply time | Destroyable? | Cost if left running |
|-------|-----------|--------------|----------------------|
| `bootstrap` | ~1 min | ❌ (holds all state) | ~cents/mo |
| `eks` | ~15 min | ✅ | ~$6–9/day |
| `platform` | ~8 min | ✅ | ~$1–2/day |

---

## CI/CD pipeline

### Authentication — no stored AWS keys

Every workflow authenticates to AWS using **OIDC**. GitHub generates a short-lived JWT per
workflow run. AWS STS exchanges it for 15-minute temporary credentials.

```
GitHub Actions JWT  →  AWS STS AssumeRoleWithWebIdentity  →  15-min temp credentials
(auto-generated        (verified against OIDC provider             (scoped to one IAM role,
 per job run)           in terraform/eks/oidc.tf)                    expires automatically)
```

### Service deploy pipeline — per service workflow

```
build job
  ├── docker build -t <ecr-url>/<service>:<git-sha> .
  └── docker push :<git-sha>      ← immutable tag

deploy-dev (branch = dev)          deploy-prod (branch = main)
  └── helm upgrade --install         └── helm upgrade --install
        --namespace dev                    --namespace prod
        -f values-dev.yaml                 -f values-prod.yaml
        --set image.tag=<sha>              --set image.tag=<sha>
        (no --wait — dev has no DB)        --wait --timeout 5m
```

Each workflow has a **concurrency group** (`deploy-<service>-<branch>`) to prevent simultaneous
runs from causing Helm lock conflicts (`another operation is in progress`).

### Terraform pipeline

```
eks job                          platform job (needs: eks)
  ├── terraform init               ├── terraform init
  ├── terraform plan               ├── terraform plan
  └── terraform apply              └── terraform apply
      (on push to main only)           (on push to main only)
```

---

## Observability

Deployed in the `monitoring` namespace via Helm:

| Component | Helm chart | Purpose |
|-----------|-----------|---------|
| Prometheus | `kube-prometheus-stack` | Scrapes `/metrics` from all pods every 15s |
| Grafana | `kube-prometheus-stack` | Dashboards — pre-built K8s + custom PromQL |
| AlertManager | `kube-prometheus-stack` | Fires alerts: CrashLoop, HighErrorRate (>10% 5xx), HighLatency (P99 > 1s) |
| Loki | `loki-stack` | Stores pod logs (24h retention, filesystem) |
| Promtail | `loki-stack` | DaemonSet that ships pod logs to Loki |

**Access Grafana locally:**
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open http://localhost:3000 — admin / cloudcare-grafana
```

**Useful PromQL queries:**
```promql
up{job=~"cloudcare.*"}                          # are all 4 services reachable?
rate(http_requests_total{job=~"cloudcare.*"}[5m]) # request rate per service
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) # P99 latency
```

**Alert rules** — defined in `monitoring/prometheus/alerts.yaml` (PrometheusRule CRD):
- `PodCrashLooping` — pod restart rate > 0 for 5 minutes
- `HighErrorRate` — HTTP 5xx rate > 10% for 5 minutes
- `HighLatency` — P99 latency > 1 second for 5 minutes

> **Node capacity note:** t3.small nodes support max 11 pods each (AWS VPC CNI limit).
> With 3 nodes (33 total slots), there is enough room for all prod services + monitoring stack.
> With 2 nodes, monitoring stack exhausted capacity — this is why the node group uses 3 nodes.

---

## Repository Structure

```
cloud-care-k8s/
│
├── README.md
│
├── services/                          ← one directory per microservice
│   ├── patient-service/
│   │   ├── app/{main,models,schemas,database}.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── appointment-service/           ← same structure
│   ├── audit-service/                 ← uses DynamoDB instead of RDS
│   ├── notification-service/          ← calls SES, no DB
│   ├── docker-compose.yml             ← local dev: all 4 services + postgres + dynamodb-local
│   └── init.sql                       ← schema seeds for local postgres
│
├── helm/                              ← one Helm chart per service
│   └── <service>/
│       ├── Chart.yaml
│       ├── values.yaml                ← base defaults
│       ├── values-dev.yaml            ← dev overrides (1 replica, no HPA, plain secrets)
│       ├── values-prod.yaml           ← prod overrides (2 replicas, HPA, IRSA, prod image)
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── hpa.yaml
│           ├── serviceaccount.yaml
│           └── _helpers.tpl
│
├── k8s/
│   └── ingress.yaml                   ← ALB Ingress (ingressClassName in spec, not metadata)
│
├── monitoring/
│   ├── prometheus/
│   │   ├── values.yaml                ← kube-prometheus-stack Helm values
│   │   │                                 (scrape configs, Grafana password, Loki datasource)
│   │   └── alerts.yaml                ← PrometheusRule CRD (3 alert rules)
│   └── loki/
│       └── values.yaml                ← loki-stack Helm values (filesystem storage, 24h retention)
│
├── terraform/
│   ├── bootstrap/main.tf              ← S3 state bucket (run once)
│   ├── eks/
│   │   ├── backend.tf                 ← S3 backend (use_lockfile=true, requires Terraform 1.10+)
│   │   ├── vpc.tf                     ← VPC, subnets, IGW, route tables
│   │   ├── eks.tf                     ← EKS cluster (API_AND_CONFIG_MAP auth mode)
│   │   │                                 node group: t3.small × 3, public subnets
│   │   │                                 EKS access entry for GitHub Actions IAM role
│   │   ├── ecr.tf                     ← 4 ECR repos
│   │   ├── oidc.tf                    ← EKS OIDC + GitHub OIDC + deploy IAM role
│   │   └── outputs.tf
│   └── platform/
│       ├── providers.tf               ← S3 backend, aws ~>6.0, helm ~>3.0
│       ├── remote_state.tf            ← reads eks stack outputs
│       ├── rds.tf                     ← RDS PostgreSQL db.t3.micro
│       ├── secrets.tf                 ← Secrets Manager (recovery_window_in_days=0)
│       ├── alb.tf                     ← ALB Ingress Controller + metrics-server (Helm)
│       └── irsa.tf                    ← DynamoDB table + IRSA roles
│
├── .github/workflows/
│   ├── deploy-patient-service.yml     ← concurrency group per branch
│   ├── deploy-appointment-service.yml
│   ├── deploy-audit-service.yml
│   ├── deploy-notification-service.yml
│   └── terraform.yml                  ← Terraform 1.10, inline apply (no tfplan file)
│
└── docs/                              ← numbered guides, one per phase
    ├── 00-roadmap.md
    ├── 01-local-setup.md
    ├── 02-microservices-split.md
    ├── 03a-k8s-concepts.md / 03b-k8s-practice.md
    ├── 04a-helm-concepts.md / 04b-helm-practice.md
    ├── 05a-eks-concepts.md  / 05b-eks-practice.md
    ├── 06a-cicd-concepts.md / 06b-cicd-practice.md
    ├── 07a-secrets-concepts.md / 07b-secrets-practice.md
    ├── 08a-hpa-concepts.md  / 08b-hpa-practice.md
    └── 09-observability.md
```

---

## Prerequisites

- **AWS account** with IAM admin user and MFA enabled
- **AWS CLI v2** authenticated (`aws sts get-caller-identity` succeeds)
- **Terraform** `>= 1.10` (required for `use_lockfile` in S3 backend)
- **kubectl** + **Helm 3** (`helm version`)
- **Docker** with Compose plugin (`docker compose version`)
- **Python 3.12** (for local dev — Docker is fine too)

---

## Quick Start — Deploy from Scratch

> Run all commands from the **project root** (`cloud-care-k8s/`) unless noted otherwise.

### Phase 0 — Bootstrap Terraform state (run once ever)

```bash
cd terraform/bootstrap
terraform init
terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"
```

### Phase 1 — Provision EKS cluster (~15 min)

```bash
cd terraform/eks
terraform init
terraform plan
terraform apply

# Configure kubectl
aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1

# Verify — should show 3 t3.small nodes in Ready state
kubectl get nodes
```

### Phase 2 — Provision platform resources (~8 min)

```bash
cd terraform/platform
terraform init
terraform apply
# Creates: RDS PostgreSQL, Secrets Manager secrets,
#          ALB Ingress Controller (Helm), Metrics Server (Helm),
#          DynamoDB audit_events table, IRSA roles
```

### Phase 3 — Initialize the database (one-time)

RDS creates the database with only the master user. Service-specific users must be created manually:

```bash
# From terraform/platform directory
MASTER_PASS=$(terraform state pull | python3 -c "
import sys, json
state = json.load(sys.stdin)
for r in state['resources']:
    if r['type'] == 'random_password' and r['name'] == 'db_master':
        print(r['instances'][0]['attributes']['result'])
")

PATIENT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/patient-service/db --query SecretString --output text \
  | python3 -c "import sys,json; from urllib.parse import urlparse; print(urlparse(json.load(sys.stdin)['DATABASE_URL']).password)")

APPT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/appointment-service/db --query SecretString --output text \
  | python3 -c "import sys,json; from urllib.parse import urlparse; print(urlparse(json.load(sys.stdin)['DATABASE_URL']).password)")

RDS_HOST=$(terraform state pull | python3 -c "
import sys, json
from urllib.parse import urlparse
state = json.load(sys.stdin)
for r in state['resources']:
    if r['type'] == 'aws_db_instance':
        ep = r['instances'][0]['attributes']['endpoint']
        print(urlparse('postgresql://' + ep).hostname)
")

# Run a one-time psql pod inside the cluster to reach private RDS
kubectl run psql-init -n prod --restart=Never --image=postgres:16 -- sleep 300
kubectl wait pod/psql-init -n prod --for=condition=Ready --timeout=60s

kubectl exec -n prod psql-init -- psql \
  "postgresql://cloudcare_admin:${MASTER_PASS}@${RDS_HOST}/cloudcare?sslmode=require" \
  -c "CREATE USER patient_svc WITH PASSWORD '${PATIENT_PASS}';" \
  -c "CREATE SCHEMA IF NOT EXISTS patients;" \
  -c "GRANT CONNECT ON DATABASE cloudcare TO patient_svc;" \
  -c "GRANT USAGE, CREATE ON SCHEMA patients TO patient_svc;" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA patients GRANT ALL ON TABLES TO patient_svc;" \
  -c "CREATE USER appt_svc WITH PASSWORD '${APPT_PASS}';" \
  -c "CREATE SCHEMA IF NOT EXISTS appointments;" \
  -c "GRANT CONNECT ON DATABASE cloudcare TO appt_svc;" \
  -c "GRANT USAGE, CREATE ON SCHEMA appointments TO appt_svc;" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA appointments GRANT ALL ON TABLES TO appt_svc;"

kubectl delete pod psql-init -n prod
```

### Phase 4 — Create K8s Secrets from Secrets Manager

```bash
PATIENT_DB_URL=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/patient-service/db --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_URL'])")

APPT_DB_URL=$(aws secretsmanager get-secret-value \
  --secret-id cloudcare-k8s/appointment-service/db --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_URL'])")

kubectl create secret generic patient-service-db-secret \
  --from-literal=DATABASE_URL="$PATIENT_DB_URL" \
  -n prod --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic appointment-service-db-secret \
  --from-literal=DATABASE_URL="$APPT_DB_URL" \
  -n prod --dry-run=client -o yaml | kubectl apply -f -
```

### Phase 5 — Build and deploy all services

> Run from the **project root** `cloud-care-k8s/` — not from inside terraform/.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1
SHA=$(git rev-parse --short HEAD)

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  ( cd services/$svc && docker build -t "$ECR:$SHA" . && docker push "$ECR:$SHA" )
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.tag="$SHA" \
    --namespace prod --create-namespace
done

kubectl get pods -n prod -w
```

### Phase 6 — Deploy monitoring stack

```bash
# Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Prometheus + Grafana + AlertManager
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f monitoring/prometheus/values.yaml \
  --version 58.3.1 --timeout 10m --wait

# Install Loki + Promtail
helm upgrade --install loki-stack grafana/loki-stack \
  --namespace monitoring \
  -f monitoring/loki/values.yaml \
  --version 2.10.2 --timeout 10m --wait

# Apply alert rules
kubectl apply -f monitoring/prometheus/alerts.yaml

# Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# http://localhost:3000  admin / cloudcare-grafana
```

### Phase 7 — Apply Ingress and verify

```bash
kubectl apply -f k8s/ingress.yaml

# Wait ~2 min for ALB to be provisioned
kubectl get ingress cloudcare-ingress -n prod

ALB=$(kubectl get ingress cloudcare-ingress -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "http://$ALB/health"
curl -X POST "http://$ALB/patients" \
  -H "Content-Type: application/json" \
  -d '{"full_name":"Jane Doe","date_of_birth":"1990-01-01","phone":"+94771234567"}'
curl "http://$ALB/patients"
curl "http://$ALB/audit"
```

---

## Local Development

```bash
cd services/
docker compose up --build

# patient-service      → http://localhost:8001/docs
# appointment-service  → http://localhost:8002/docs
# audit-service        → http://localhost:8003/docs
# notification-service → http://localhost:8004/docs
```

---

## Cost

| Resource | Est. daily cost | Notes |
|---|---|---|
| EKS control plane | ~$2.40/day | No free tier — destroy when not working |
| 3× t3.small nodes | ~$1.60/day | $0.023/hr each |
| RDS `db.t3.micro` | ~$0.40/day | 750 hrs/mo free tier covers first year |
| ALB (Ingress) | ~$0.50/day | Fixed hourly + LCU charge |
| ECR (4 repos) | ~$0 | 500 MB/mo free tier |
| DynamoDB | ~$0 | Pay-per-request; near-zero at lab volume |
| Secrets Manager | ~$0.01/day | $0.40/secret/month |
| **Estimated total** | **~$4.90/day** | Destroy EKS + platform when not working |

> **Workflow**: develop and iterate locally with Docker Compose (zero cost).
> Spin up EKS only for integration tests. Destroy immediately after.

---

## Teardown

Destroy in reverse-dependency order:

```bash
# 1. Uninstall monitoring stack
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall loki-stack -n monitoring

# 2. Uninstall service releases
helm uninstall patient-service appointment-service audit-service notification-service -n prod
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall metrics-server -n kube-system

# 3. Destroy platform stack (RDS, DynamoDB, Secrets Manager, IAM roles)
cd terraform/platform && terraform destroy

# 4. Destroy EKS stack (cluster, nodes, VPC, ECR)
cd ../eks && terraform destroy
```

> **ALB cleanup warning:** The ALB created by the Ingress Controller is NOT managed by Terraform.
> If `terraform destroy` hangs on subnets/VPC, the ALB or its ENIs are still alive.
> Manual cleanup:
> ```bash
> # Delete the ALB
> aws elbv2 delete-load-balancer --region ap-south-1 \
>   --load-balancer-arn $(aws elbv2 describe-load-balancers --region ap-south-1 \
>     --query 'LoadBalancers[?contains(LoadBalancerName,`k8s`)].LoadBalancerArn' --output text)
>
> # Delete leftover security groups created by the ALB controller
> # (look for names starting with k8s-prod- or k8s-traffic-)
> aws ec2 describe-security-groups --region ap-south-1 \
>   --filters "Name=vpc-id,Values=<vpc-id>" \
>   --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text \
>   | xargs -n1 aws ec2 delete-security-group --region ap-south-1 --group-id
>
> # Then re-run terraform destroy — VPC will delete cleanly
> ```

> **ECR cleanup:** ECR repos containing images will block destroy.
> Force-delete with: `aws ecr delete-repository --region ap-south-1 --repository-name <name> --force`

> **Secrets Manager:** Uses `recovery_window_in_days = 0` to force-delete immediately,
> so re-apply works the next day without "already scheduled for deletion" errors.

---

## Known Issues & Resolutions

| Issue | Root Cause | Fix Applied |
|-------|-----------|-------------|
| NodeCreationFailure (33+ min timeout) | DIY NAT couldn't route EKS API / ECR traffic from private subnets | Moved node group to public subnets |
| `t3.micro` nodes OOMKilled | Too little RAM for EKS CNI + system pods + app pods | Changed to `t3.small` |
| ALB controller CrashLoopBackOff — `EC2MetadataError 401` | Controller couldn't discover VPC ID via IMDSv2 | Added explicit `vpcId` to Helm values in `alb.tf` |
| `password authentication failed for user "patient_svc"` | Terraform creates Secrets Manager entries but never runs `CREATE USER` in PostgreSQL | Manual one-time psql pod init (Phase 3) |
| `Secrets Manager: already scheduled for deletion` | Re-applied platform within 7-day deletion window | `recovery_window_in_days = 0` in `secrets.tf` |
| `DATABASE_URL` KeyError / empty env var | `helm --set` mangles URLs containing `://` and `@` | K8s Secret + `secretKeyRef` in deployment template |
| Helm provider v3 breaking change | `kubernetes {}` block syntax changed | Updated `providers.tf` and `alb.tf` |
| Monitoring stack `Too many pods` timeout | t3.small nodes at max capacity (11 pods × 2 nodes = 22) | Scaled HPA minReplicas to 1, added 3rd node |
| `unknown field metadata.ingressClassName` | `ingressClassName` placed under `metadata` instead of `spec` | Moved to `spec.ingressClassName: alb` in `k8s/ingress.yaml` |
| CI/CD `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust policy had wrong GitHub username in `sub` claim | Fixed to `repo:chala2001/cloud-care-k8s:*` in `oidc.tf` |
| CI Terraform `use_lockfile: Unsupported argument` | `use_lockfile` in S3 backend requires Terraform 1.10+ | Bumped `terraform_version` to `1.10.0` in `terraform.yml` |
| Platform Terraform `Kubernetes cluster unreachable` | GitHub Actions IAM role not in EKS auth | Added `aws_eks_access_entry` + `aws_eks_access_policy_association` in `eks.tf` |
| Platform CI `cannot re-use a name that is still in use` | Helm releases installed manually; Terraform state didn't know they existed | `terraform import helm_release.alb_controller kube-system/aws-load-balancer-controller` |
| CI `Failed to load tfplan as a plan file` | `terraform plan -out=tfplan` failed silently (continue-on-error) leaving no file | Removed `-out=tfplan`; apply uses `terraform apply -auto-approve` inline |
| Helm lock `another operation is in progress` | Multiple service pipelines triggered simultaneously on merge | Added `concurrency` groups to all deploy workflows |
| `terraform destroy` hung on subnets/VPC | ALB and its ENIs still alive after cluster delete | Manual ALB delete + security group cleanup (see Teardown section) |

---

## Documentation & Learning Path

The [`docs/`](docs/) folder contains numbered guides walking through every phase:

| Phase | Topic | Doc |
|------:|-------|-----|
| 0 | Roadmap | [00-roadmap.md](docs/00-roadmap.md) |
| 1 | Local dev setup | [01-local-setup.md](docs/01-local-setup.md) |
| 2 | Microservices split | [02-microservices-split.md](docs/02-microservices-split.md) |
| 3 | Kubernetes manifests | [03a-k8s-concepts.md](docs/03a-k8s-concepts.md) · [03b-k8s-practice.md](docs/03b-k8s-practice.md) |
| 4 | Helm charts | [04a-helm-concepts.md](docs/04a-helm-concepts.md) · [04b-helm-practice.md](docs/04b-helm-practice.md) |
| 5 | EKS with Terraform | [05a-eks-concepts.md](docs/05a-eks-concepts.md) · [05b-eks-practice.md](docs/05b-eks-practice.md) |
| 6 | CI/CD — GitHub Actions + OIDC | [06a-cicd-concepts.md](docs/06a-cicd-concepts.md) · [06b-cicd-practice.md](docs/06b-cicd-practice.md) |
| 7 | IRSA + Secrets Manager | [07a-secrets-concepts.md](docs/07a-secrets-concepts.md) · [07b-secrets-practice.md](docs/07b-secrets-practice.md) |
| 8 | HPA | [08a-hpa-concepts.md](docs/08a-hpa-concepts.md) · [08b-hpa-practice.md](docs/08b-hpa-practice.md) |
| 9 | Prometheus + Grafana + Loki | [09-observability.md](docs/09-observability.md) |

---

<sub>Architecture references: AWS Well-Architected Framework · CNCF Landscape ·
Built as a portfolio project demonstrating AWS DevOps, SRE, and Kubernetes engineering practices.
The application logic is intentionally minimal — the infrastructure, pipelines, and
operational practices are the deliverable.</sub>
