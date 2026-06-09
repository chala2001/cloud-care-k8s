# 10 — Multi-Environment: Dev and Prod Namespaces

> **Goal of this doc:** understand how we run dev and prod environments inside the
> same Kubernetes cluster using namespaces, Helm value overrides, and Kustomize
> overlays — and why this is more efficient than separate clusters.

---

## 1. The Two Approaches to Multi-Environment

**Option A — Separate clusters per environment:**
```
dev-cluster  (EKS)   ← dev workloads
prod-cluster (EKS)   ← prod workloads
```
Strong isolation, but doubles your EKS cost (~$146/mo instead of ~$73/mo).

**Option B — Namespaces within one cluster:**
```
cloudcare-k8s cluster
├── namespace: dev    ← dev workloads
├── namespace: prod   ← prod workloads
└── namespace: monitoring
```
More cost-efficient. Sufficient isolation for a learning project and many real
production systems.

We use Option B. The trade-off: a cluster-level failure (e.g. etcd problem) affects
both environments. For a portfolio project this is fine. Very large companies use
separate clusters; most mid-size companies use namespace isolation.

> 🧠 **Interview answer:** *"We use namespace isolation within a single cluster to
> keep costs down, with RBAC preventing any service account in `dev` from touching
> `prod` resources. For a safety-critical production system we'd consider separate
> clusters for stronger blast-radius isolation."*

---

## 2. Namespace Isolation

### 2.1 Create Namespaces

```yaml
# k8s/base/namespaces.yaml
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
```

### 2.2 NetworkPolicy: Dev Cannot Talk to Prod

By default, any pod can reach any other pod in any namespace. Add a NetworkPolicy to
enforce that dev pods cannot call prod pods:

`k8s/base/network-policies.yaml`:
```yaml
# Deny all ingress from other namespaces by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-from-other-namespaces
  namespace: prod
spec:
  podSelector: {}           # applies to all pods in prod
  policyTypes:
    - Ingress
  ingress:
    # Allow only from within prod namespace
    - from:
        - podSelector: {}
    # Allow from monitoring namespace (Prometheus scraping)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

Now a bug in a dev pod cannot accidentally call a prod service, and a compromised dev
pod cannot read prod data.

---

## 3. Helm: One Chart, Multiple Releases

You already saw this in Doc 04 — the same Helm chart, different values:

```bash
# Install patient-service in dev namespace
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# Install patient-service in prod namespace (same chart, different values)
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values-prod.yaml \
  --namespace prod

# List releases per namespace
helm list -n dev
helm list -n prod
```

Both releases are named `patient-service`, but they're in different namespaces —
Kubernetes treats them as completely separate deployments.

### Differences Between Dev and Prod (Summary)

| Setting | Dev | Prod |
|---|---|---|
| `replicaCount` | 1 | 2 |
| `image.pullPolicy` | Never (local) | Always (from ECR) |
| `image.tag` | local | git SHA |
| `resources.requests` | 64Mi / 50m | 128Mi / 100m |
| `hpa.enabled` | false | true |
| `hpa.minReplicas` | — | 2 |
| `hpa.maxReplicas` | — | 6 |
| `externalSecret.enabled` | false | true |
| Log level | DEBUG | WARNING |

---

## 4. Kustomize: Base + Overlays

While Helm handles per-service differences, **Kustomize** handles *shared* resources
that differ between environments — like the Ingress, RBAC, and namespace-wide settings.

> 🧠 **Helm vs Kustomize:** Helm is good for *per-service* packaging (deployment +
> service + hpa + secret in one chart). Kustomize is good for *cross-cutting* concerns
> — things that span multiple services or configure the namespace as a whole. Many
> teams use both together, as we do here.

### Directory Structure

```
k8s/
├── base/                    ← resources that apply everywhere
│   ├── namespaces.yaml
│   ├── network-policies.yaml
│   ├── ingress.yaml
│   ├── rbac.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/                 ← dev-specific patches
    │   ├── kustomization.yaml
    │   └── ingress-patch.yaml
    └── prod/                ← prod-specific patches
        ├── kustomization.yaml
        └── ingress-patch.yaml
```

### base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespaces.yaml
  - network-policies.yaml
  - ingress.yaml
  - rbac.yaml

commonLabels:
  managed-by: kustomize
```

### base/ingress.yaml (the template)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: NAMESPACE_PLACEHOLDER    # will be patched per environment
  annotations:
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

### overlays/dev/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev         # all resources get namespace: dev

bases:
  - ../../base

patches:
  - path: ingress-patch.yaml

commonLabels:
  environment: dev
```

### overlays/dev/ingress-patch.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: dev
  annotations:
    # dev ALB is internal-facing — not public
    alb.ingress.kubernetes.io/scheme: internal
```

### overlays/prod/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod

bases:
  - ../../base

patches:
  - path: ingress-patch.yaml

commonLabels:
  environment: prod
```

### overlays/prod/ingress-patch.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: prod
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing    # prod is public
    alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
```

### Apply with Kustomize

```bash
# Preview what will be applied to dev
kubectl kustomize k8s/overlays/dev

# Apply to dev
kubectl apply -k k8s/overlays/dev

# Apply to prod
kubectl apply -k k8s/overlays/prod
```

---

## 5. RBAC: Least Privilege per Namespace

Create a ServiceAccount for each service. The ServiceAccount in `dev` cannot access
`prod` resources and vice versa.

`k8s/base/rbac.yaml`:
```yaml
# Each service gets its own ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: patient-service
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: appointment-service
---
# A Role that allows read-only access to ConfigMaps (if needed)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: service-role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
# Bind the role to all service accounts in the namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: service-role-binding
subjects:
  - kind: ServiceAccount
    name: patient-service
  - kind: ServiceAccount
    name: appointment-service
roleRef:
  kind: Role
  name: service-role
  apiGroup: rbac.authorization.k8s.io
```

When Kustomize applies this with `namespace: dev`, all these resources go into `dev`.
When applied with `namespace: prod`, they go into `prod`. The same base RBAC policy
applies to both, but the resources are entirely separate.

---

## 6. The Full Deployment Flow

When a developer merges to `main` and changes `patient-service`:

```
1. patient-service.yml workflow triggers

2. pytest — runs tests

3. docker build + push to ECR:
   cloudcare-k8s-patient-service:a3f8b2c

4. helm upgrade patient-service ./helm/patient-service
     --set image.tag=a3f8b2c
     -f values-dev.yaml
     --namespace dev
   → patient-service pod in dev namespace updates

5. kubectl rollout status deployment/patient-service -n dev
   → verify dev is healthy

6. Manual approval gate (GitHub environment: production)
   → reviewer approves

7. helm upgrade patient-service ./helm/patient-service
     --set image.tag=a3f8b2c
     -f values-prod.yaml
     --namespace prod
   → patient-service pod in prod namespace updates

8. kubectl rollout status deployment/patient-service -n prod
   → verify prod is healthy
```

The other three services are untouched. Their pods keep running in both namespaces.

---

## 7. Verifying Isolation

Verify that a dev pod cannot reach a prod service:

```bash
# Get a shell in a dev pod
kubectl exec -it deployment/patient-service -n dev -- /bin/sh

# Try to reach prod patient-service
# (short DNS name only resolves within the same namespace)
curl http://patient-service:8001/patients

# Try the full DNS name across namespaces
curl http://patient-service.prod.svc.cluster.local:8001/patients
# Should be blocked by the NetworkPolicy — connection times out
```

---

## 8. What "Done" Looks Like for This Project

When you can do all of the following, this project is complete:

- [ ] `terraform apply` in all three stacks — cluster is up, nodes are ready
- [ ] `helm upgrade --install` deploys all four services to both `dev` and `prod`
- [ ] `kubectl apply -k k8s/overlays/prod` sets up Ingress, RBAC, network policies
- [ ] Push a commit to `main` that touches `patient-service/` → pipeline runs → dev
      deploys automatically, prod waits for approval
- [ ] Approve the prod deployment → pod updates in prod, Grafana shows the new replica
- [ ] `kubectl get hpa -n prod` shows HPA running for all services
- [ ] Open Grafana at `localhost:3000` and see request rate, error rate, latency
- [ ] Query Loki for ERROR logs across all prod services
- [ ] `helm rollback patient-service 1 -n prod` works and old pod is running
- [ ] `terraform destroy` in eks + platform stacks → cost drops to ~$0
- [ ] `terraform apply` again → cluster restored in ~15 minutes

If you can do all of this from memory, you're ready to talk about it in an interview.

---

## 9. The Interview Story

> *"CloudCare v1 was a monolithic FastAPI application deployed on an EC2 Auto Scaling
> Group. I learned Terraform, VPC networking, IAM, RDS, and GitHub Actions by building it.
>
> Once I was confident with the fundamentals, I re-platformed it onto Kubernetes to
> understand how modern teams actually operate containerised workloads. I split the
> monolith into four independent microservices — patient, appointment, audit, and
> notification. Each service has its own Dockerfile, Helm chart, ECR repository, and
> GitHub Actions pipeline. A change to patient-service deploys only patient-service;
> the other three are untouched.
>
> I run dev and prod as namespaces within the same EKS cluster. Each namespace has its
> own Helm values, network policies, RBAC, and IRSA roles. Secrets come from AWS
> Secrets Manager via the External Secrets Operator — they never touch Git.
>
> The observability stack is Prometheus for metrics, Grafana for dashboards, and Loki
> for log aggregation. I have RED dashboards per service and alerting rules for error
> rate, pod crash-looping, and HPA saturation.
>
> The whole thing costs ~$0 when I'm not running EKS. When EKS is up, it's ~$90/month.
> I can destroy and recreate the entire stack in about 15 minutes with Terraform."*

---

## ✅ Final Checkpoint

You've completed all 10 phases. Answer these to confirm you're ready:

1. What is the core architectural difference between CloudCare v1 and v2?
2. What are the four microservices and what does each own?
3. What is schema-per-service isolation and why do we use it?
4. What is a Kubernetes Deployment vs a Pod vs a Service?
5. What does a Helm chart's `values-prod.yaml` do?
6. What does EKS cost per hour? Why do we use a NAT instance?
7. What is IRSA and how does a pod get AWS credentials?
8. What does the External Secrets Operator do?
9. What is the RED method?
10. How do you roll back a bad production deployment with Helm?

**Congratulations — you've built a production-grade Kubernetes DevOps system.** 🎉
