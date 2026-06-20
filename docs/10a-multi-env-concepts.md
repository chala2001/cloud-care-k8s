# 10a — Multi-Environment: Concepts and Mental Model

> **Goal:** understand how dev and prod environments live inside the same Kubernetes
> cluster using namespaces, and why Helm + Kustomize together is the cleanest way to
> manage the differences between them. Read this fully before going to 10b.

---

## 1. The Problem — Two Environments, One Cluster

When you run a real service, you need at least two environments:

- **Dev** — where you test your changes before anyone sees them. Can break. Uses cheap local resources (a Postgres pod, DynamoDB Local). Deploys automatically on every push.
- **Prod** — where real users go. Must not break. Uses real AWS resources (RDS, DynamoDB). Requires a manual approval gate before deploying.

The naive approach is two separate EKS clusters:

```
dev-cluster  (EKS)   → ~$2.40/day
prod-cluster (EKS)   → ~$2.40/day
                       ─────────────
                       ~$4.80/day wasted
```

That doubles your AWS bill. For a portfolio project, and for most mid-size companies,
**namespace isolation within one cluster** gives you enough separation at half the cost.

---

## 2. Kubernetes Namespaces — What They Are

A namespace is a **logical partition** inside a cluster. Resources in different
namespaces are isolated from each other by default:

```
cloudcare-k8s cluster
├── namespace: dev
│   ├── patient-service pod
│   ├── appointment-service pod
│   ├── postgres pod          ← local DB, only in dev
│   └── dynamodb-local pod    ← local DynamoDB, only in dev
│
├── namespace: prod
│   ├── patient-service pod   ← connects to RDS (not the dev postgres)
│   ├── appointment-service pod
│   ├── audit-service pod     ← uses real DynamoDB via IRSA
│   └── notification-service pod
│
└── namespace: monitoring
    ├── prometheus pod
    ├── grafana pod
    └── loki pod + promtail daemonset
```

Key property: the name `patient-service` means different things in different
namespaces. `kubectl get pods -n dev` shows the dev pod. `kubectl get pods -n prod`
shows the prod pod. They are completely separate Kubernetes objects.

---

## 3. What Is Actually Different Between Dev and Prod

The differences are not just replicas. The entire infrastructure layer is different:

| Concern | Dev | Prod |
|---|---|---|
| **Database** | Postgres pod inside cluster (`infrastructure.yaml`) | RDS PostgreSQL (Terraform-provisioned) |
| **DynamoDB** | DynamoDB Local pod inside cluster (`infrastructure.yaml`) | Real AWS DynamoDB |
| **Secrets** | Hardcoded in `values-dev.yaml` (safe — local only) | AWS Secrets Manager via ExternalSecret |
| **Image source** | Locally built minikube image (`pullPolicy: Never`) | ECR image with git SHA tag (`pullPolicy: Always`) |
| **Replicas** | 1 per service (cost) | 2 per service (HA) |
| **HPA** | Disabled | Enabled |
| **Resources** | 64Mi / 50m CPU | 128Mi / 100m CPU |
| **Log level** | DEBUG | WARNING |
| **IRSA** | Fake credentials (`awsAccessKeyId: local`) | Real IAM role via IRSA |
| **Ingress scheme** | internet-facing (dev access) | internet-facing + explicit subnet IDs |

The Helm chart is **identical** — the same template files render differently because
of what `values-dev.yaml` and `values-prod.yaml` say.

---

## 4. Helm's Role — One Chart, Two Releases

The same Helm chart is installed twice — once per namespace — as two completely
independent **Helm releases**:

```
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-prod.yaml \
  --namespace prod
```

Both releases are named `patient-service` but they live in different namespaces.
Helm tracks them separately — `helm list -n dev` and `helm list -n prod` both show
a release called `patient-service` but they have independent rollback histories.

```
helm rollback patient-service 1 -n dev    ← rolls back only dev
helm rollback patient-service 1 -n prod   ← rolls back only prod
```

---

## 5. Kustomize's Role — Cross-Cutting Concerns

Helm handles per-service packaging (deployment + service + hpa + secret in one chart).
But some resources span the whole environment and don't belong to any single service:

- Namespace definitions
- NetworkPolicy (who can talk to whom)
- RBAC (which service accounts have which permissions)
- Ingress (the single entry point routing to all services)
- Infrastructure (the postgres and dynamodb-local pods that dev needs)

These are managed with **Kustomize** — a tool built into `kubectl`. Kustomize
uses a `base/` + `overlays/` pattern:

```
k8s/
├── base/                    ← resources that exist in every environment
│   ├── namespaces.yaml      ← dev, prod, monitoring namespace definitions
│   ├── infrastructure.yaml  ← postgres + dynamodb-local pods (used in dev)
│   ├── ingress.yaml         ← base ingress template
│   └── kustomization.yaml   ← lists what's in the base
│
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml   ← "use base, add namespace: dev, apply patches"
    │   └── ingress-patch.yaml   ← dev-specific ingress changes
    └── prod/
        ├── kustomization.yaml   ← "use base, add namespace: prod, apply patches"
        └── ingress-patch.yaml   ← prod-specific ingress changes
```

When you run `kubectl apply -k k8s/overlays/prod`, Kustomize:
1. Reads the base
2. Applies the prod overlay (patches, namespace injection, label additions)
3. Renders the final YAML
4. Applies it to the cluster

You never edit the base directly for environment-specific changes. You patch it
from the overlay.

---

## 6. Helm vs Kustomize — When to Use Each

This is a common interview question:

| Use Helm for... | Use Kustomize for... |
|---|---|
| Per-service resources (Deployment, Service, HPA, ExternalSecret) | Cross-cutting resources (Ingress, RBAC, NetworkPolicy, Namespaces) |
| Parameterised templates with values files | Simple patches on top of existing YAML |
| Packaging something you'd reuse across projects | Structuring an environment's shared config |
| Services from third parties (installing Prometheus, Loki) | Your own cluster-wide policy and routing |

Both tools are used together in this project. This is how most real teams operate.

---

## 7. NetworkPolicy — Enforcing Dev/Prod Isolation

By default, any pod in any namespace can reach any other pod in any namespace.
This means a broken dev pod could accidentally call prod services, or a compromised
dev pod could read prod data.

A `NetworkPolicy` is a Kubernetes resource that restricts which pods can talk to
which other pods:

```
Without NetworkPolicy:
  dev/patient-service pod → prod/patient-service pod   ← ALLOWED (dangerous!)

With NetworkPolicy on prod namespace:
  dev/patient-service pod → prod/patient-service pod   ← BLOCKED
  prod/patient-service → prod/appointment-service      ← ALLOWED (same namespace)
  monitoring/prometheus → prod/patient-service:/metrics ← ALLOWED (Prometheus scraping)
```

NetworkPolicy rules are enforced by the **VPC CNI plugin** at the network level —
not by the application. Even if the dev pod sends a TCP packet, it gets dropped
before reaching the prod pod.

---

## 8. Dev Infrastructure — Pods Instead of AWS Services

In dev, you do not want to pay for RDS or use the real DynamoDB table. Instead,
`k8s/base/infrastructure.yaml` runs lightweight stand-ins inside the cluster:

```
dev namespace
├── postgres pod (image: postgres:16)
│   └── Service: postgres:5432
│   └── dev services connect via DATABASE_URL: postgresql://admin:local_password@postgres:5432/cloudcare
│
└── dynamodb-local pod (image: amazon/dynamodb-local:2.3.0)
    └── Service: dynamodb-local:8000
    └── audit-service connects via: http://dynamodb-local:8000
```

In prod, these pods do not exist. The services connect to:
- RDS endpoint (from Terraform output, injected as a K8s Secret via ExternalSecret)
- Real AWS DynamoDB (credentials from IRSA — no endpoint override needed)

This is why `values-dev.yaml` has `DATABASE_URL` hardcoded and
`values-prod.yaml` has `databaseSecretName: patient-service-db-secret` instead.

---

## 9. The Deployment Flow — Dev Auto, Prod Gated

When a developer pushes to `main` and changes `patient-service`:

```
push to main
    │
    ▼
GitHub Actions: patient-service workflow
    │
    ├─ Step 1: pytest
    ├─ Step 2: docker build + push to ECR (tag = git SHA)
    ├─ Step 3: helm upgrade --namespace dev  ← automatic, no approval needed
    ├─ Step 4: kubectl rollout status -n dev  ← verify dev is healthy
    │
    └─ Step 5: wait for approval (GitHub environment: production)
               ↓  (reviewer clicks Approve)
    ├─ Step 6: helm upgrade --namespace prod ← only runs after approval
    └─ Step 7: kubectl rollout status -n prod
```

The four other services are untouched by this pipeline. Their pods in both
namespaces keep running with their previous images.

---

## 10. Helm Rollback — Your Safety Net

Every `helm upgrade` creates a new **revision** in Helm's history. If a prod deploy
goes wrong you roll back with one command:

```bash
# See the history
helm history patient-service -n prod
# REVISION  STATUS      CHART                    APP VERSION
# 1         superseded  patient-service-0.1.0    abc1234
# 2         deployed    patient-service-0.1.0    def5678   ← current (broken)

# Roll back to revision 1
helm rollback patient-service 1 -n prod
# Kubernetes does a rolling update back to the old image
# zero downtime — old pods come up before new pods go down
```

This works because Helm stores the full rendered YAML of every revision in a
Kubernetes Secret. Rolling back simply re-applies the old rendered manifest.

---

## 11. Namespace DNS — How Services Find Each Other

Inside a namespace, services find each other using short names:

```
patient-service calls appointment-service:
  http://appointment-service:8002/appointments
  (short name — works within the same namespace)
```

Across namespaces (which you generally want to avoid):

```
http://appointment-service.prod.svc.cluster.local:8002
         └── service name
                        └── namespace
                             └── always "svc.cluster.local"
```

This is why NetworkPolicy matters — without it, the dev `patient-service` pod
could use the full DNS name to call the prod `appointment-service`.

---

**You understand the multi-environment model. Go to
[10b — Multi-Environment Practice](10b-multi-env-practice.md)
to apply every file, complete the final deployment checklist, and read the
interview story.**
