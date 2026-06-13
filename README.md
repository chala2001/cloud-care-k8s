# CloudCare-K8s — AWS DevOps Showcase v2

> **The evolution of CloudCare.**
> Same hospital management system. Migrated from a monolithic EC2/ASG deployment
> to a **microservices architecture orchestrated on Kubernetes** — the way modern
> engineering teams actually run production workloads.

**Region** `ap-south-1` (Mumbai) · **IaC** Terraform 1.9+ · **Orchestration** Kubernetes 1.30 on EKS ·
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

## Tech Stack

Twenty-eight tools, grouped by what they do in the system.

<table>
  <tr>
    <td width="33%" valign="top">
      <h4>Cloud &amp; Orchestration</h4>
      <p>
        <img src="https://img.shields.io/badge/AWS-232F3E?style=for-the-badge&logo=amazonwebservices&logoColor=white" alt="AWS"/>
        <img src="https://img.shields.io/badge/Kubernetes%201.30-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="Kubernetes"/>
        <img src="https://img.shields.io/badge/Amazon%20EKS-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white" alt="EKS"/>
        <img src="https://img.shields.io/badge/Terraform%201.9-7B42BC?style=for-the-badge&logo=terraform&logoColor=white" alt="Terraform"/>
        <img src="https://img.shields.io/badge/Helm%203-0F1689?style=for-the-badge&logo=helm&logoColor=white" alt="Helm 3"/>
        <img src="https://img.shields.io/badge/Kustomize-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="Kustomize"/>
      </p>
      <sub>EKS managed control plane; Terraform declares every resource; Helm packages per-service charts; Kustomize overlays for dev/prod differences.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Compute &amp; Networking</h4>
      <p>
        <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker"/>
        <img src="https://img.shields.io/badge/ECR-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white" alt="ECR"/>
        <img src="https://img.shields.io/badge/ALB%20Ingress-FF9900?style=for-the-badge" alt="ALB Ingress"/>
        <img src="https://img.shields.io/badge/VPC-232F3E?style=for-the-badge&logo=amazonaws&logoColor=white" alt="VPC"/>
        <img src="https://img.shields.io/badge/NAT%20Instance-232F3E?style=for-the-badge" alt="NAT"/>
      </p>
      <sub>EKS t3.micro node group; one ECR repo per service; AWS ALB Ingress Controller routes external traffic; NAT instance saves ~$32/mo vs NAT Gateway.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Edge (v1 — cloud-care repo)</h4>
      <p>
        <img src="https://img.shields.io/badge/CloudFront-8C4FFF?style=for-the-badge" alt="CloudFront"/>
        <img src="https://img.shields.io/badge/S3%20%28static%29-569A31?style=for-the-badge&logo=amazons3&logoColor=white" alt="S3 static"/>
      </p>
      <sub>Defined in the companion cloud-care (v1) repo — not in this repo. CloudFront serves the React SPA from private S3 and forwards /api/* to this cluster's ALB Ingress.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Data</h4>
      <p>
        <img src="https://img.shields.io/badge/RDS%20PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="RDS PostgreSQL"/>
        <img src="https://img.shields.io/badge/DynamoDB-4053D6?style=for-the-badge&logo=amazondynamodb&logoColor=white" alt="DynamoDB"/>
        <img src="https://img.shields.io/badge/Secrets%20Manager-DD344C?style=for-the-badge" alt="Secrets Manager"/>
        <img src="https://img.shields.io/badge/External%20Secrets-3D8BD3?style=for-the-badge" alt="External Secrets Operator"/>
      </p>
      <sub>Schema-per-service on shared RDS; audit events on DynamoDB; External Secrets Operator syncs Secrets Manager → Kubernetes Secrets automatically.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Observability</h4>
      <p>
        <img src="https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white" alt="Prometheus"/>
        <img src="https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white" alt="Grafana"/>
        <img src="https://img.shields.io/badge/Loki-F46800?style=for-the-badge" alt="Loki"/>
        <img src="https://img.shields.io/badge/CloudWatch-FF4F8B?style=for-the-badge&logo=amazoncloudwatch&logoColor=white" alt="CloudWatch"/>
        <img src="https://img.shields.io/badge/X--Ray-FF4F8B?style=for-the-badge" alt="X-Ray"/>
      </p>
      <sub>Prometheus scrapes all pods + node exporters; Grafana dashboards service health & latency; Loki aggregates logs via Promtail; CloudWatch covers AWS-native resources.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Identity &amp; CI/CD</h4>
      <p>
        <img src="https://img.shields.io/badge/IAM%20%2B%20IRSA-DD344C?style=for-the-badge" alt="IAM + IRSA"/>
        <img src="https://img.shields.io/badge/GitHub%20Actions-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions"/>
      </p>
      <sub>IRSA gives each pod its own AWS identity — no node-level credentials; keyless CI via OIDC; one pipeline per service for independent deployability.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Application</h4>
      <p>
        <img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI"/>
      </p>
      <sub>4 Python 3.12 FastAPI microservices — the simplest CRUD needed to give the Kubernetes infrastructure something real to run. No frontend code in this repo.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Local Dev</h4>
      <p>
        <img src="https://img.shields.io/badge/minikube-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="minikube"/>
        <img src="https://img.shields.io/badge/Docker%20Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker Compose"/>
      </p>
      <sub>Full stack runs locally via Docker Compose; manifests validated on minikube — no cloud costs during development.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Messaging</h4>
      <p>
        <img src="https://img.shields.io/badge/Amazon%20SES-DD344C?style=for-the-badge" alt="SES"/>
        <img src="https://img.shields.io/badge/SNS-FF4F8B?style=for-the-badge" alt="SNS"/>
      </p>
      <sub>notification-service calls SES for transactional email; SNS fans out CloudWatch alarms to ops email.</sub>
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
| 4 | **GitOps deployment** — Helm chart is the source of truth, CI applies it | `helm/`, workflows |
| 5 | **IRSA least-privilege** — pod-level AWS permissions, not node-level | `terraform/eks/irsa.tf` |
| 6 | **External Secrets Operator** — secrets live in Secrets Manager, never in Git | `helm/*/templates/externalsecret.yaml` |
| 7 | **Multi-environment with manual approval gate** — `dev` vs `prod` namespace | `deploy-prod` job, GitHub environments |
| 8 | **Three-pillar observability** — metrics (Prometheus), logs (Loki), dashboards (Grafana) | `monitoring/` |
| 9 | **Keyless CI/CD** — OIDC, no stored AWS keys, `sub` claim pinned to repo + ref | `terraform/eks/oidc.tf` |
| 10 | **Database-per-service pattern** — schema isolation with documented upgrade path | `docs/02-microservices-split.md` |

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
- [Documentation & learning path](#documentation--learning-path)

---

## Architecture at a glance

Users hit **CloudFront**. Static React assets come from a private **S3** bucket via Origin
Access Control. API requests (`/api/*`) are forwarded to an **AWS ALB Ingress Controller**
which routes them to the appropriate microservice **pods** inside the **EKS cluster**.

Four microservices run in the `prod` namespace: `patient-service`, `appointment-service`,
`audit-service`, and `notification-service` — each independently deployable with its own
ECR repo, Helm chart, and GitHub Actions pipeline. Services talk to a private
**RDS PostgreSQL** instance using schema isolation. The **External Secrets Operator** syncs
credentials from **Secrets Manager** into Kubernetes Secrets at pod startup.

The monitoring stack (Prometheus + Grafana + Loki) runs inside the cluster in its own
namespace and scrapes metrics and logs from every pod.

---

## Architecture diagram

```mermaid
flowchart TB
    User([Users])

    subgraph Edge["AWS Edge"]
        CF["Amazon CloudFront\n(HTTPS, free *.cloudfront.net cert)"]
    end

    S3["S3 Bucket\n(React SPA, private + OAC)"]

    subgraph VPC["VPC 10.0.0.0/16 — ap-south-1"]
        IGW{{Internet Gateway}}

        subgraph Pub["Public subnets (AZ-a, AZ-b)"]
            ALB["AWS ALB\n(Ingress Controller)"]
            NAT["NAT Instance\nt3.micro"]
        end

        subgraph EKS["EKS Cluster"]
            subgraph NS_PROD["Namespace: prod"]
                PS["patient-service\n:8001"]
                APPS["appointment-service\n:8002"]
                AUS["audit-service\n:8003"]
                NS2["notification-service\n:8004"]
            end
            subgraph NS_MON["Namespace: monitoring"]
                PROM["Prometheus"]
                GRAF["Grafana"]
                LOKI["Loki + Promtail"]
            end
            ESO["External Secrets\nOperator"]
        end

        subgraph DBT["Private DB subnets (AZ-a, AZ-b)"]
            RDS[("RDS PostgreSQL 16\nschema: patients\nschema: appointments")]
        end
    end

    subgraph AWSsvc["AWS Services"]
        ECR[("ECR\n4 Docker repos")]
        SM[("Secrets Manager\nDB credentials")]
        CW["CloudWatch\nmetrics · logs"]
        DDB[("DynamoDB\naudit_events")]
        SES["Amazon SES\nemail"]
    end

    User -- HTTPS --> CF
    CF -- "/*" --> S3
    CF -- "/api/*" --> ALB
    IGW --- ALB
    IGW --- NAT
    ALB --> PS & APPS & AUS & NS2
    PS & APPS --> RDS
    AUS --> DDB
    NS2 --> SES
    ESO -. sync secrets .-> SM
    PS & APPS & AUS & NS2 -. pull image .-> ECR
    PROM -. scrape metrics .-> PS & APPS & AUS & NS2
    PROM --> GRAF
    LOKI -. collect logs .-> PS & APPS & AUS & NS2
    CW -. AWS-native metrics .-> GRAF
```

---

## Microservices Breakdown

Each service is independently deployable with its own Docker image, ECR repo, Helm chart,
GitHub Actions workflow, and database schema.

| Service | Port | Owns | Stores data in |
|---|---|---|---|
| `patient-service` | 8001 | `patients` PostgreSQL schema | RDS |
| `appointment-service` | 8002 | `appointments` PostgreSQL schema | RDS |
| `audit-service` | 8003 | `audit_events` DynamoDB table | DynamoDB |
| `notification-service` | 8004 | Nothing persistent — calls SES | — |

---

## Request flow

A typical "load the patients page, then book an appointment" sequence, including pod startup
secret sync:

```mermaid
sequenceDiagram
    actor User
    participant CF as CloudFront
    participant S3 as S3 (SPA)
    participant ALB as ALB Ingress
    participant PS as patient-service
    participant AS as appointment-service
    participant SM as Secrets Manager
    participant RDS as RDS PostgreSQL

    rect rgb(238,245,255)
    Note over User,RDS: First page load (static assets)
    User->>CF: GET /
    CF->>S3: GET index.html (OAC, SigV4)
    S3-->>CF: 200 OK
    CF-->>User: 200 (cached at edge)
    end

    rect rgb(238,255,238)
    Note over User,RDS: Pod startup — External Secrets sync
    PS->>SM: ExternalSecret reconciler → GetSecretValue
    SM-->>PS: credentials → mounted as K8s Secret env vars
    end

    rect rgb(255,245,235)
    Note over User,RDS: Create a patient
    User->>CF: POST /api/patients { ... }
    CF->>ALB: forward (Host header routing)
    ALB->>PS: route to patient-service pod :8001
    PS->>RDS: INSERT INTO patients.patients ...
    RDS-->>PS: row
    PS-->>ALB: 201 Created
    ALB-->>CF: 201
    CF-->>User: 201 Created
    end

    rect rgb(245,238,255)
    Note over User,RDS: Book an appointment
    User->>CF: POST /api/appointments { patient_id, ... }
    CF->>ALB: forward
    ALB->>AS: route to appointment-service :8002
    AS->>RDS: INSERT INTO appointments.appointments ...
    RDS-->>AS: row
    AS-->>User: 201 Created
    end
```

---

## Network topology

Six subnets across two AZs, three tiers — identical topology to v1, with EKS nodes replacing
the ASG:

```mermaid
flowchart TB
    Internet((Internet))
    IGW{{Internet Gateway}}

    subgraph VPC["VPC — 10.0.0.0/16"]

        subgraph AZa["Availability Zone ap-south-1a"]
            PubA["Public subnet\n10.0.0.0/24\n(ALB, NAT)"]
            AppA["Private app subnet\n10.0.10.0/24\n(EKS nodes)"]
            DbA["Private DB subnet\n10.0.20.0/24\n(RDS primary)"]
        end

        subgraph AZb["Availability Zone ap-south-1b"]
            PubB["Public subnet\n10.0.1.0/24\n(ALB standby)"]
            AppB["Private app subnet\n10.0.11.0/24\n(EKS nodes)"]
            DbB["Private DB subnet\n10.0.21.0/24\n(RDS standby)"]
        end

        RTpub["Public route table\n0.0.0.0/0 → IGW"]
        RTpriv["Private route table\n0.0.0.0/0 → NAT instance"]
    end

    Internet --- IGW
    IGW --- PubA
    IGW --- PubB
    PubA -.assoc.-> RTpub
    PubB -.assoc.-> RTpub
    AppA -.assoc.-> RTpriv
    AppB -.assoc.-> RTpriv
    DbA  -.assoc.-> RTpriv
    DbB  -.assoc.-> RTpriv
```

| CIDR | Tier | Public? | Purpose |
|------|------|---------|---------|
| `10.0.0.0/24`, `10.0.1.0/24` | Public | ✅ (route → IGW) | ALB Ingress, NAT instance |
| `10.0.10.0/24`, `10.0.11.0/24` | App (private) | ❌ (egress via NAT) | EKS worker nodes |
| `10.0.20.0/24`, `10.0.21.0/24` | DB (private) | ❌ (local only) | RDS PostgreSQL |

> DB subnets have **no NAT route** — the database has zero egress and is only reachable
> from the app subnet.

---

## Security architecture

### Defense in depth — the security-group chain

Each tier accepts traffic **only from the tier directly in front of it**, by referencing the
upstream security group, not an IP range:

```mermaid
flowchart LR
    I([Internet]) -- ":80, :443" --> ALB["alb-sg"]
    ALB -- ":8001–8004\n(SG reference)" --> EKS["eks-node-sg"]
    EKS -- ":5432\n(SG reference)" --> D["db-sg"]

    style ALB fill:#dbeafe,stroke:#1d4ed8,color:#000
    style EKS fill:#fef3c7,stroke:#b45309,color:#000
    style D   fill:#fee2e2,stroke:#b91c1c,color:#000
```

| SG | Ingress | Source | Egress |
|----|---------|--------|--------|
| `alb-sg` | 80, 443 (TCP) | `0.0.0.0/0` | all |
| `eks-node-sg` | 8001–8004 (TCP) | **`alb-sg`** | all |
| `db-sg` | 5432 (TCP) | **`eks-node-sg`** | all |

### IAM principles applied

- **No long-lived AWS keys in GitHub** — CI authenticates via GitHub OIDC →
  `sts:AssumeRoleWithWebIdentity` → 1-hour creds per job, scoped via the `sub`
  claim to `repo:owner/name:ref:refs/heads/main`.
- **IRSA per pod** — each microservice gets its own IAM role via the EKS OIDC provider,
  not a shared node-level instance profile. A compromised pod cannot use another service's
  AWS permissions.
- **External Secrets Operator** — pods never touch Secrets Manager directly; the operator
  syncs credentials into Kubernetes Secrets with its own scoped IRSA role.
- **CloudFront-only S3 access** — S3 bucket policy allows reads only when
  `aws:SourceArn` matches this distribution's ARN (OAC).
- **IMDSv2 enforced** on all EKS nodes (`http_tokens = "required"`) to block SSRF-based
  credential theft.

---

## Kubernetes resource model

How a single service looks inside the cluster — every service follows this same pattern:

```mermaid
flowchart TB
    subgraph NS["Kubernetes Namespace: prod"]
        direction TB
        subgraph SVC["patient-service"]
            D1["Deployment\n(replicas: 2–5)"]
            SVC1["Service\nClusterIP :8001"]
            HPA1["HPA\ntarget CPU 60%"]
            ES1["ExternalSecret\n↓ sync ↓\nK8s Secret"]
            CM1["ConfigMap\nDB host, port, name"]
        end
        ING["Ingress\n(aws-load-balancer-controller annotations)\n/api/patients → patient-service"]
    end

    ESOp["External Secrets\nOperator (cluster)"]
    SMgr["Secrets Manager\n(AWS)"]

    ING --> SVC1
    SVC1 --> D1
    HPA1 -. scales .-> D1
    ES1 -. mounts env .-> D1
    CM1 -. mounts env .-> D1
    ESOp -. reconcile .-> ES1
    ESOp -. GetSecretValue .-> SMgr
```

---

## Data model

```mermaid
erDiagram
    PATIENTS ||--o{ APPOINTMENTS : "has many"

    PATIENTS {
        int    id           PK
        string full_name
        date   date_of_birth
        string phone
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

    NOTIFICATION_LOG {
        string   id             PK
        string   recipient_email
        string   subject
        string   status
        datetime created_at
    }
```

`PATIENTS` and `APPOINTMENTS` live in **RDS PostgreSQL** under schema-per-service isolation
(`patients.patients`, `appointments.appointments`). `AUDIT_EVENTS` lives in **DynamoDB**
(high-volume, write-heavy, no joins). `NOTIFICATION_LOG` is a fire-and-forget record
written by notification-service before calling SES.

---

## Infrastructure modules

Three Terraform stacks, each with its own state key in the shared backend
(`s3://cloudcare-k8s-tfstate-<account>/<stack>/terraform.tfstate`):

```mermaid
flowchart TB
    BS["bootstrap\nS3 state bucket + DynamoDB lock table"]

    EKS["eks\nVPC · subnets · IGW · NACLs · SGs\nEKS cluster · managed node group\n4× ECR repos · IRSA roles · OIDC provider"]

    PLAT["platform\nRDS PostgreSQL · Secrets Manager\nALB Ingress Controller · External Secrets Operator\nCloudFront · S3 · SNS · CloudWatch alarms"]

    BS -.->|hosts state for all| EKS
    EKS --> PLAT
```

| Stack | State key | Reads from | Free-tier risk |
|-------|-----------|------------|----------------|
| `bootstrap` | `bootstrap/terraform.tfstate` (local) | — | ✅ ~cents/mo |
| `eks` | `eks/terraform.tfstate` | — | ⚠️ EKS control plane ~$73/mo |
| `platform` | `platform/terraform.tfstate` | `eks` | ⚠️ RDS + ALB hours |

> **Habit:** destroy `eks` and `platform` when not actively working.
> Develop and test manifests on minikube locally (free). Spin up EKS only for integration
> testing and screenshots.

---

## CI/CD pipeline

### Authentication — no stored AWS keys

Every workflow authenticates to AWS using **OIDC** (OpenID Connect). GitHub generates
a short-lived JWT per workflow run. AWS STS exchanges it for 15-minute temporary
credentials scoped to the `cloudcare-k8s-github-deploy` IAM role.
No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` is stored anywhere in GitHub.

```
GitHub Actions JWT  →  AWS STS AssumeRoleWithWebIdentity  →  15-min temp credentials
(auto-generated        (verified against OIDC provider             (scoped to one role,
 per job run)           registered in terraform/eks/oidc.tf)        expires automatically)
```

The OIDC trust policy is pinned to `repo:chala2001/cloud-care-k8s:*` — no other
repository can assume this role.

---

### First-time setup — must be manual

The OIDC provider and `github_deploy` IAM role are created by Terraform. Until Terraform
runs, GitHub Actions has nothing to authenticate against. This is a one-time bootstrap:

```
1. terraform apply (eks)       ← run manually from your laptop
      creates: OIDC provider, github_deploy IAM role, ECR repos, EKS cluster

2. terraform apply (platform)  ← run manually from your laptop
      creates: RDS, Secrets Manager secrets, ALB controller, ESO

3. From this point forward — GitHub Actions handles all future infrastructure
   and service changes automatically.
```

---

### Branch strategy

```
feature/xyz  ──●──●──●
                        \
dev          ─────────────●──────────────●──────
                          ↑              \
                   merge: test here        \
                   (EKS dev namespace)      \
main         ────────────────────────────────●──
                                             ↑
                                      merge: goes to prod
                                      (EKS prod namespace)
```

| Branch | Purpose | Protected? |
|--------|---------|-----------|
| `main` | Production — what real users see | Yes — PR required |
| `dev` | Staging — integration test before prod | Recommended |
| `feature/*` | Your active work — private until pushed | No |

---

### Git workflow — step by step

```bash
# 1. Start from dev (never work directly on main)
git checkout dev && git pull origin dev

# 2. Create a feature branch
git checkout -b feature/your-feature-name

# 3. Make changes, commit
git add .
git commit -m "describe what changed"

# 4. Push feature branch — triggers NOTHING in CI/CD
git push -u origin feature/your-feature-name

# 5. Open PR on GitHub: feature/your-feature-name → dev
#    If terraform/ files changed: terraform plan runs and posts output as PR comment
#    Service workflows: do not run on PRs, only on branch push

# 6. Merge PR into dev
#    → If service code changed: build image → push to ECR → helm deploy to EKS dev namespace
#    → If terraform/ changed: terraform plan only (apply is blocked on dev)
#    Test the result in the dev namespace

# 7. Open PR: dev → main
#    If terraform/ changed: terraform plan runs again as PR comment (final review)

# 8. Merge PR into main
#    → If service code changed: build image → push to ECR → helm deploy to EKS prod namespace
#    → If terraform/ changed: terraform apply runs (real AWS infrastructure changes)
```

---

### What triggers what — full map

| Event | Branch | Files changed | Workflow | What it does |
|-------|--------|---------------|----------|--------------|
| Open PR | any → dev/main | `terraform/**` | `terraform.yml` | `terraform plan` — posts output as PR comment, no changes applied |
| Open PR | any → dev/main | `services/*/**` | nothing | service workflows don't run on PRs |
| Merge / push | `dev` | `services/patient-service/**` | `deploy-patient-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **dev** namespace |
| Merge / push | `dev` | `services/appointment-service/**` | `deploy-appointment-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **dev** namespace |
| Merge / push | `dev` | `services/audit-service/**` | `deploy-audit-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **dev** namespace |
| Merge / push | `dev` | `services/notification-service/**` | `deploy-notification-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **dev** namespace |
| Merge / push | `dev` | `terraform/**` | `terraform.yml` | `terraform plan` only — no apply on dev |
| Merge / push | `main` | `services/patient-service/**` | `deploy-patient-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **prod** namespace |
| Merge / push | `main` | `services/appointment-service/**` | `deploy-appointment-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **prod** namespace |
| Merge / push | `main` | `services/audit-service/**` | `deploy-audit-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **prod** namespace |
| Merge / push | `main` | `services/notification-service/**` | `deploy-notification-service.yml` | build → push ECR `:git-sha` → `helm upgrade` to **prod** namespace |
| Merge / push | `main` | `terraform/**` | `terraform.yml` | `terraform apply` (eks stack first, then platform) |
| Push `feature/*` | any | any | nothing | feature branches are not watched |

---

### Service deploy pipeline — inside each workflow

Every service workflow has 3 jobs. Branch determines which deploy job runs:

```
build job (always runs)
  ├── docker build -t ecr-url/cloudcare-k8s-<service>:<git-sha> .
  ├── docker push :git-sha    ← immutable tag — used for rollback
  └── docker push :latest     ← mutable tag — convenient for local pulls

deploy-dev job (only when branch = dev)
  ├── helm upgrade --install <service> ./helm/<service>
  │     -f values-dev.yaml              ← 1 replica, DEBUG logs, no HPA, local secrets
  │     --set image.tag=<git-sha>
  │     --namespace dev
  └── kubectl rollout status            ← fails the job if pods don't become Ready

deploy-prod job (only when branch = main)
  ├── helm upgrade --install <service> ./helm/<service>
  │     -f values-prod.yaml             ← 2 replicas, HPA enabled, ESO secrets, WARNING logs
  │     --set image.tag=<git-sha>
  │     --namespace prod
  └── kubectl rollout status
```

The image is **always rebuilt** on every merge — every commit has a unique git SHA,
so a new tag is always produced. Images are never reused between branches.

---

### Terraform pipeline — inside terraform.yml

```
eks job
  ├── terraform init      (downloads providers, connects to S3 backend)
  ├── terraform validate  (syntax check — no AWS calls)
  ├── terraform plan      (always runs — shows what would change)
  └── terraform apply     (ONLY on push to main — never on PRs or dev branch)

platform job (needs: eks — waits for eks job to finish)
  ├── same steps as eks job
  └── reads eks outputs (VPC IDs, cluster name) via terraform_remote_state
```

`terraform apply` is gated to `main` branch only. Every PR shows the plan
as a comment — you see exactly what AWS resources will change before merging.

---

### Pipeline architecture diagram

```mermaid
flowchart TD
    Dev([Developer])

    Dev -->|"git push -u origin feature/xyz\n(triggers nothing)"| FEAT["feature/* branch"]
    FEAT -->|"Open PR → dev"| PR1{"PR event\n(dev)"}
    PR1 -->|"terraform/** changed"| PLAN1["terraform plan\n→ post as PR comment"]
    PR1 -->|"service code changed"| SKIP["no service workflow\n(PRs don't deploy)"]

    FEAT -->|"Merge PR"| DEV["dev branch\npush event"]
    DEV -->|"services/patient-service/**"| BD["build job\ndocker build + push :git-sha to ECR"]
    BD --> DD["deploy-dev job\nhelm upgrade → EKS dev namespace\nvalues-dev.yaml"]
    DEV -->|"terraform/**"| TP_DEV["terraform plan only\n(no apply on dev)"]

    DEV -->|"Open PR → main"| PR2{"PR event\n(main)"}
    PR2 -->|"terraform/** changed"| PLAN2["terraform plan\n→ post as PR comment"]

    DEV -->|"Merge PR"| MAIN["main branch\npush event"]
    MAIN -->|"services/patient-service/**"| BP["build job\ndocker build + push :git-sha to ECR"]
    BP --> DP["deploy-prod job\nhelm upgrade → EKS prod namespace\nvalues-prod.yaml"]
    MAIN -->|"terraform/**"| TA["terraform apply\neks stack → platform stack"]

    BD & BP -->|"OIDC"| STS["AWS STS\nAssumeRoleWithWebIdentity"]
    DD & DP & TA -->|"OIDC"| STS
    STS --> ROLE["IAM role\ncloudcare-k8s-github-deploy\n15-min temp credentials"]
```

---

## Observability

Three pillars run inside the cluster in the `monitoring` namespace:

```mermaid
flowchart LR
    subgraph Services["prod namespace"]
        PS["patient-service\n/metrics"]
        AS["appointment-service\n/metrics"]
        AUS["audit-service\n/metrics"]
        NS2["notification-service\n/metrics"]
    end

    subgraph Mon["monitoring namespace"]
        PROM["Prometheus\n(scrape interval: 15s)"]
        GRAF["Grafana\n(dashboards)"]
        LOKI["Loki"]
        PT["Promtail\n(DaemonSet)"]
    end

    CW["CloudWatch\n(RDS, ALB, EKS\ncontrol plane)"]
    SNS["SNS → email\n(ops alerts)"]

    PS & AS & AUS & NS2 -- "/metrics" --> PROM
    PT -- "pod logs" --> PS & AS & AUS & NS2
    PT -- "forward" --> LOKI
    PROM --> GRAF
    LOKI --> GRAF
    CW --> GRAF
    PROM -- "alert rules" --> SNS
```

| Signal | Source | Where to find it |
|--------|--------|-----------------|
| Pod metrics (CPU, memory, RPS, error rate) | Prometheus | Grafana — service health dashboard |
| Pod logs | Loki via Promtail DaemonSet | Grafana — Loki explorer |
| RDS metrics (CPU, connections, storage) | CloudWatch | Grafana — AWS datasource |
| ALB metrics (5xx, request count, latency) | CloudWatch | Grafana — AWS datasource |
| EKS control-plane logs | CloudWatch Logs | `/aws/eks/cloudcare-k8s/cluster` |
| Ops alerts | Prometheus Alertmanager → SNS | Email to `cloudcare-ops-alerts` |

---

## Repository Structure

```
cloud-care-k8s/
│
├── README.md                          ← this file
│
├── services/                          ← one directory per microservice
│   ├── patient-service/
│   │   ├── app/{main,models,schemas,database}.py
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── tests/test_patients.py
│   ├── appointment-service/
│   │   ├── app/{main,models,schemas,database}.py
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── tests/test_appointments.py
│   ├── audit-service/
│   │   ├── app/{main,schemas}.py
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── tests/test_audit.py
│   ├── notification-service/
│   │   ├── app/{main,schemas}.py
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── tests/test_notification.py
│   ├── docker-compose.yml             ← local dev: all 4 services + postgres
│   └── init.sql                       ← schema seeds for local postgres
│
├── helm/                              ← one Helm chart per service
│   └── patient-service/
│       ├── chart.yml
│       ├── values.yml                 ← base values
│       ├── values-dev.yml
│       ├── values-prod.yml
│       └── templates/
│           ├── deployement.yml
│           ├── service.yml
│           ├── hpa.yml
│           ├── externalsecret.yml
│           └── _helpers.tpl
│
├── k8s/                               ← raw manifests (Kustomize)
│   └── base/
│       ├── patient-service.yaml
│       ├── appointment-service.yaml
│       ├── audit-service.yaml
│       ├── notification-service.yaml
│       ├── ingress.yaml
│       ├── infrastructure.yaml
│       └── namespaces.yaml
│
├── terraform/                         ← 3 independent stacks
│   ├── bootstrap/                     ← S3 state bucket + DynamoDB lock (run once)
│   ├── eks/                           ← VPC, EKS cluster, node group, ECR repos, IRSA, OIDC
│   └── platform/                      ← RDS, Secrets Manager, ALB Ingress Controller,
│                                          External Secrets Operator, CloudFront, S3
│
├── monitoring/
│   ├── prometheus/                    ← scrape configs, alert rules
│   ├── grafana/dashboards/            ← dashboard JSON exports
│   └── loki/                          ← Loki + Promtail config
│
├── .github/workflows/
│   ├── deploy-patient-service.yml     ← build → ECR → helm upgrade (per service)
│   ├── deploy-appointment-service.yml
│   ├── deploy-audit-service.yml
│   ├── deploy-notification-service.yml
│   └── terraform.yml                  ← plan on PR, apply on main
│   (no frontend.yml — frontend deploy lives in cloud-care/)
│
└── docs/                              ← 11 numbered guides, one per phase
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

- **AWS account** with a non-root IAM admin user, MFA enabled, and budgets configured
  (see [v1 Doc 03](../cloud-care/docs/03-aws-account-and-cost-safety.md))
- **AWS CLI v2** authenticated (`aws sts get-caller-identity` succeeds)
- **Terraform** `>= 1.9`
- **kubectl** + **Helm 3** (`helm version`)
- **Docker Desktop** (includes Docker Compose)
- **minikube** or **kind** for local Kubernetes dev
- **Python 3.12** (for local backend dev — Docker is enough)

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
kubectl get nodes  # should show 2 t3.micro nodes Ready
```

### Phase 2 — Provision platform resources

```bash
cd terraform/platform
terraform init && terraform apply
# Provisions: RDS, Secrets Manager, ALB Ingress Controller,
#             External Secrets Operator, S3, CloudFront
```

### Phase 3 — Build and deploy all services

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  SHA=$(git rev-parse --short HEAD)
  ( cd services/$svc && docker build -t "$ECR:$SHA" . && docker push "$ECR:$SHA" )
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yml \
    --set image.tag="$SHA" \
    --namespace prod --create-namespace
done

kubectl get pods -n prod -w  # watch all pods reach Running
```

### Phase 4 — Verify

```bash
# Get the ALB DNS name from the Ingress
kubectl get ingress -n prod

# Hit the API directly via ALB
ALB=$(kubectl get ingress -n prod -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
curl "http://$ALB/api/patients"
curl "http://$ALB/api/appointments"

# To wire a frontend, point the cloud-care React app's VITE_API_URL at this ALB.
# That frontend lives in the companion cloud-care/ repo.
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

# deploy a single service to the dev namespace
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yml \
  --namespace dev --create-namespace

kubectl get pods -n dev -w
kubectl port-forward svc/patient-service 8001:8001 -n dev
# open http://localhost:8001/docs
```

### Run tests

```bash
cd services/patient-service
pip install -r requirements.txt
pytest tests/ -v

# or across all services:
for svc in patient-service appointment-service audit-service notification-service; do
  echo "--- $svc ---"
  ( cd services/$svc && pip install -r requirements.txt -q && pytest tests/ -v )
done
```

---

## Cost

Designed to stay within the AWS Free Tier for all resources **except EKS itself**.

| Resource | Est. monthly cost | Notes |
|---|---|---|
| EKS control plane | ~$73 | No free tier — the biggest cost; destroy when not working |
| 2× t3.micro worker nodes | ~$0 | Covered by 750 hrs/mo free tier |
| RDS `db.t3.micro` | ~$0 | Covered by 750 hrs/mo free tier |
| ALB (Ingress Controller) | ~$16 | Fixed hourly + LCU charge |
| NAT instance (`t3.micro`) | ~$0 | Free tier; saves ~$32/mo vs NAT Gateway |
| CloudFront | ~$0 | 1 TB out + 10 M requests/mo free tier |
| ECR (4 repos) | ~$0 | 500 MB/mo free tier easily covers this |
| DynamoDB, Lambda, SES | ~$0 | Always-free quotas dwarf lab usage |
| **Estimated total** | **~$90/mo** | Within $150 AWS Activate / free-credit budgets |

> **Workflow**: develop and iterate locally with Docker Compose and minikube (zero cost).
> Only spin up EKS for integration tests and screenshots. Destroy with the teardown command
> the moment you're done.

---

## Teardown

Destroy in reverse-dependency order to return to ~$0:

```bash
# uninstall all Helm releases first
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod 2>/dev/null || true
  helm uninstall $svc -n dev  2>/dev/null || true
done

# destroy Terraform stacks in reverse order
for stack in platform eks; do
  ( cd terraform/$stack && terraform destroy -auto-approve )
done
```

Leave `bootstrap/` alone — it holds the Terraform state for everything else and costs
cents per month.

---

## Documentation & Learning Path

The [`docs/`](docs/) folder contains 11 numbered guides walking through every phase with
concepts, Terraform code, step-by-step instructions, and verification steps.

Start at the [**roadmap**](docs/00-roadmap.md) or jump to any phase below:

| Phase | Topic | Doc |
|------:|-------|-----|
| 0 | Setup · Docker Compose · minikube basics | [00-roadmap.md](docs/00-roadmap.md), [01-local-setup.md](docs/01-local-setup.md) |
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

- **[cloud-care](../cloud-care)** — v1: monolithic FastAPI on EC2/ASG — the foundation this builds on.
- [AWS EKS documentation](https://docs.aws.amazon.com/eks/)
- [Kubernetes documentation](https://kubernetes.io/docs/)
- [Helm documentation](https://helm.sh/docs/)
- [External Secrets Operator](https://external-secrets.io/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

---

<sub>Architecture references: AWS Well-Architected Framework · CNCF Landscape ·
Built as a portfolio project demonstrating AWS DevOps, SRE, and Kubernetes engineering practices.
The application logic is intentionally minimal — the infrastructure, pipelines, and
operational practices are the deliverable.</sub>
