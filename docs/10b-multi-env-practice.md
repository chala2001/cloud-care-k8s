# 10b — Multi-Environment Practice: Every File, Every Line

> **Read 10a first.** This doc walks through every file in the `k8s/` directory,
> builds the Kustomize overlay structure, deploys both environments, and verifies
> isolation. It ends with the full project checklist and the interview story.

---

## 1. What Already Exists in k8s/

```
k8s/
├── base/
│   ├── namespaces.yaml       ← already written — 3 namespaces
│   ├── infrastructure.yaml   ← already written — postgres + dynamodb-local for dev
│   ├── ingress.yaml          ← base ingress (dev-oriented)
│   ├── appointment-service.yaml
│   ├── audit-service.yaml
│   ├── notification-service.yaml
│   └── patient-service.yaml
└── ingress.yaml              ← prod ingress (manually applied at the moment)
```

What you will add in this doc:

```
k8s/
├── base/
│   ├── network-policies.yaml    ← new: dev cannot reach prod
│   ├── rbac.yaml                ← new: one ServiceAccount per service
│   └── kustomization.yaml       ← new: lists base resources
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml       ← new
    │   └── ingress-patch.yaml       ← new
    └── prod/
        ├── kustomization.yaml       ← new
        └── ingress-patch.yaml       ← new: uses real subnet IDs + all 4 routes
```

---

## 2. k8s/base/namespaces.yaml — every line (already exists)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
  labels:
    environment: dev
    # labels let NetworkPolicy selectors identify this namespace
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
  # no environment label — monitoring is cluster-wide, not environment-specific
```

---

## 3. k8s/base/infrastructure.yaml — every line (already exists)

This file deploys the local stand-ins that dev uses instead of real AWS services.
It lives in the base but is only applied to the `dev` namespace via Kustomize.

```yaml
# ── PostgreSQL — stands in for RDS in dev ─────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: dev
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "cloudcare"
            - name: POSTGRES_USER
              value: "admin"
            - name: POSTGRES_PASSWORD
              value: "local_password"
              # hardcoded password — acceptable in dev (cluster is local)
              # in prod, password comes from RDS Terraform + Secrets Manager
          volumeMounts:
            - name: init-sql
              mountPath: /docker-entrypoint-initdb.d
              # postgres:16 runs all .sql files in this directory on first start
              # this creates schemas and tables from services/init.sql
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "admin", "-d", "cloudcare"]
            initialDelaySeconds: 5
            periodSeconds: 5
            # readinessProbe tells Kubernetes: "only send traffic here when the DB is ready"
            # without this, services start before the DB is accepting connections → crashes
      volumes:
        - name: init-sql
          configMap:
            name: postgres-init
            # you must create this ConfigMap from services/init.sql:
            # kubectl create configmap postgres-init --from-file=init.sql=services/init.sql -n dev
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: dev
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
  # ClusterIP = only reachable from inside the cluster
  # services connect using: postgresql://admin:local_password@postgres:5432/cloudcare
  # "postgres" resolves to this Service's ClusterIP within the dev namespace

---
# ── DynamoDB Local — stands in for real DynamoDB in dev ───────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dynamodb-local
  namespace: dev
  labels:
    app: dynamodb-local
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dynamodb-local
  template:
    metadata:
      labels:
        app: dynamodb-local
    spec:
      containers:
        - name: dynamodb-local
          image: amazon/dynamodb-local:2.3.0
          command: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]
          # -sharedDb: all tables visible to all connections (useful for local testing)
          # -inMemory: data lost when pod restarts — fine for dev (not persistent storage)
          ports:
            - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: dynamodb-local
  namespace: dev
spec:
  selector:
    app: dynamodb-local
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
  # audit-service in dev connects using: http://dynamodb-local:8000
  # in prod, no endpoint override → boto3 uses real AWS DynamoDB automatically
```

---

## 4. k8s/base/network-policies.yaml — create this file

```yaml
# Block dev namespace from reaching prod namespace
# Without this, any pod in dev can call any pod in prod via full DNS name
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-from-dev
  namespace: prod
  # this policy lives in prod — it controls who can reach prod pods
spec:
  podSelector: {}
  # {} = applies to ALL pods in the prod namespace
  policyTypes:
    - Ingress
    # Ingress = controls incoming traffic to prod pods
    # (Egress = outgoing, not restricted here)
  ingress:
    - from:
        - podSelector: {}
          namespaceSelector:
            matchLabels:
              environment: prod
          # Allow: only pods from within prod can reach prod
          # The namespaces.yaml labels prod with environment: prod
          # so this selector resolves to: the prod namespace itself

    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          # Allow: Prometheus (in monitoring namespace) can scrape prod pods
          # Prometheus needs to reach prod pods' /metrics endpoints
          # without this exception, Prometheus cannot scrape and you get no metrics
```

---

## 5. k8s/base/rbac.yaml — create this file

```yaml
# ServiceAccount per service — used by Helm charts and IRSA bindings
apiVersion: v1
kind: ServiceAccount
metadata:
  name: patient-service
  # Kustomize will inject namespace: dev or namespace: prod when applying overlays
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: appointment-service
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audit-service
  # audit-service's ServiceAccount in prod is annotated with IRSA role ARN
  # (done in helm/audit-service/templates/serviceaccount.yaml, not here)
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: notification-service
---
# Role: what service accounts are allowed to do within the namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: service-role
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list"]
    # services can read ConfigMaps and Secrets in their own namespace
    # they cannot create, update, or delete them
    # they cannot touch resources in other namespaces at all
---
# RoleBinding: attach the Role to each ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: service-role-binding
subjects:
  - kind: ServiceAccount
    name: patient-service
  - kind: ServiceAccount
    name: appointment-service
  - kind: ServiceAccount
    name: audit-service
  - kind: ServiceAccount
    name: notification-service
roleRef:
  kind: Role
  name: service-role
  apiGroup: rbac.authorization.k8s.io
  # roleRef is the Role to assign — it is a one-way bind: same Role, 4 subjects
```

---

## 6. k8s/base/kustomization.yaml — create this file

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespaces.yaml
  - infrastructure.yaml
  - network-policies.yaml
  - rbac.yaml
  - ingress.yaml
  # lists every file in the base that Kustomize should include
  # overlays reference this base and patch on top of it

commonLabels:
  managed-by: kustomize
  # adds this label to every resource created from this base
  # makes it easy to find all Kustomize-managed resources:
  # kubectl get all -A -l managed-by=kustomize
```

---

## 7. k8s/overlays/dev/kustomization.yaml — create this file

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev
# injects "namespace: dev" into every resource from the base
# this is how the same namespaces.yaml, rbac.yaml, ingress.yaml
# gets applied to the dev namespace without duplicating files

resources:
  - ../../base
  # ../../base = relative path to k8s/base/
  # includes ALL files listed in base/kustomization.yaml

patches:
  - path: ingress-patch.yaml
    # applies the dev-specific ingress patch on top of base/ingress.yaml

commonLabels:
  environment: dev
  # adds environment: dev label to every resource in this overlay
  # lets you filter: kubectl get all -n dev -l environment=dev
```

---

## 8. k8s/overlays/dev/ingress-patch.yaml — create this file

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: dev
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    # dev ALB is internet-facing so you can test from your browser
    # in a stricter setup you'd use "internal" — but for a portfolio project
    # internet-facing in dev is fine (just don't put sensitive data there)
    alb.ingress.kubernetes.io/target-type: ip
    # target-type: ip = ALB routes directly to pod IPs (VPC CNI assigns real VPC IPs)
    # better performance than "instance" mode (skips one kube-proxy hop)
```

---

## 9. k8s/overlays/prod/kustomization.yaml — create this file

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod

resources:
  - ../../base

patches:
  - path: ingress-patch.yaml

commonLabels:
  environment: prod
```

---

## 10. k8s/overlays/prod/ingress-patch.yaml — create this file

This is based on the actual prod ingress already in `k8s/ingress.yaml`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudcare-ingress
  namespace: prod
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip

    alb.ingress.kubernetes.io/subnets: subnet-0fde620180c088cec,subnet-085727ba919384594
    # explicitly pin the public subnet IDs where the ALB is placed
    # these are the two public subnets from vpc.tf (10.0.0.0/24 and 10.0.1.0/24)
    # EKS can auto-discover subnets from cluster tags, but explicit IDs is more reliable
    # if you destroy and recreate the EKS stack, update these values from terraform output

    alb.ingress.kubernetes.io/healthcheck-path: /health
    # ALB sends a GET /health to each target to decide if it is healthy
    # unhealthy targets are removed from rotation until they pass health checks

    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
    # check each target every 30 seconds

  ingressClassName: alb
  # newer way to specify the ingress class (replaces kubernetes.io/ingress.class annotation)
  # both work — ingressClassName is preferred in Kubernetes 1.18+

spec:
  rules:
    - http:
        paths:
          - path: /patients
            pathType: Prefix
            backend:
              service:
                name: patient-service
                port:
                  number: 8001
          - path: /appointments
            pathType: Prefix
            backend:
              service:
                name: appointment-service
                port:
                  number: 8002
          - path: /audit
            pathType: Prefix
            backend:
              service:
                name: audit-service
                port:
                  number: 8003
          - path: /notify
            pathType: Prefix
            backend:
              service:
                name: notification-service
                port:
                  number: 8004
          - path: /health
            pathType: Exact
            # Exact vs Prefix: /health only, not /healthz or /health/foo
            # used by the ALB healthcheck itself — hits patient-service as the canary
            backend:
              service:
                name: patient-service
                port:
                  number: 8001
```

---

## 11. Deploy Both Environments

### Step 1 — Apply shared cluster resources with Kustomize

```bash
# Preview dev — see what YAML will be generated before applying
kubectl kustomize k8s/overlays/dev

# Apply dev namespace resources
kubectl apply -k k8s/overlays/dev

# Apply prod namespace resources
kubectl apply -k k8s/overlays/prod
```

Verify:
```bash
kubectl get namespaces
# NAME         STATUS   AGE
# dev          Active   30s
# prod         Active   30s
# monitoring   Active   30s

kubectl get networkpolicies -n prod
# NAME           POD-SELECTOR   AGE
# deny-from-dev  <none>         30s
```

### Step 2 — Create the postgres ConfigMap for dev

```bash
kubectl create configmap postgres-init \
  --from-file=init.sql=services/init.sql \
  --namespace dev
# this ConfigMap is mounted into the postgres pod as /docker-entrypoint-initdb.d/init.sql
# postgres runs it on first startup to create schemas and tables
```

### Step 3 — Deploy all 4 services to dev

```bash
# patient-service
helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values.yaml \
  -f helm/patient-service/values-dev.yaml \
  --namespace dev

# appointment-service
helm upgrade --install appointment-service ./helm/appointment-service \
  -f helm/appointment-service/values.yaml \
  -f helm/appointment-service/values-dev.yaml \
  --namespace dev

# audit-service
helm upgrade --install audit-service ./helm/audit-service \
  -f helm/audit-service/values.yaml \
  -f helm/audit-service/values-dev.yaml \
  --namespace dev

# notification-service
helm upgrade --install notification-service ./helm/notification-service \
  -f helm/notification-service/values.yaml \
  -f helm/notification-service/values-dev.yaml \
  --namespace dev
```

Verify:
```bash
kubectl get pods -n dev
# NAME                                    READY   STATUS    RESTARTS
# patient-service-xxx                     1/1     Running   0
# appointment-service-xxx                 1/1     Running   0
# audit-service-xxx                       1/1     Running   0
# notification-service-xxx                1/1     Running   0
# postgres-xxx                            1/1     Running   0
# dynamodb-local-xxx                      1/1     Running   0
```

### Step 4 — Deploy all 4 services to prod

```bash
# Set your ECR account ID
ECR="670794226080.dkr.ecr.ap-south-1.amazonaws.com"

helm upgrade --install patient-service ./helm/patient-service \
  -f helm/patient-service/values.yaml \
  -f helm/patient-service/values-prod.yaml \
  --set image.repository=$ECR/cloudcare-k8s-patient-service \
  --namespace prod

helm upgrade --install appointment-service ./helm/appointment-service \
  -f helm/appointment-service/values.yaml \
  -f helm/appointment-service/values-prod.yaml \
  --set image.repository=$ECR/cloudcare-k8s-appointment-service \
  --namespace prod

helm upgrade --install audit-service ./helm/audit-service \
  -f helm/audit-service/values.yaml \
  -f helm/audit-service/values-prod.yaml \
  --set image.repository=$ECR/cloudcare-k8s-audit-service \
  --namespace prod

helm upgrade --install notification-service ./helm/notification-service \
  -f helm/notification-service/values.yaml \
  -f helm/notification-service/values-prod.yaml \
  --set image.repository=$ECR/cloudcare-k8s-notification-service \
  --namespace prod
```

---

## 12. Values Differences — Dev vs Prod Side by Side

Actual values from this project. Use these as reference.

### patient-service

| Setting | `values-dev.yaml` | `values-prod.yaml` |
|---|---|---|
| `replicaCount` | 1 | 2 |
| `image.pullPolicy` | `Never` (local minikube image) | `Always` (ECR) |
| `image.tag` | `local` | `latest` (CI overrides with git SHA) |
| `resources.requests.cpu` | `50m` | `100m` |
| `resources.requests.memory` | `64Mi` | `128Mi` |
| `resources.limits.cpu` | `200m` | `500m` |
| `resources.limits.memory` | `128Mi` | `256Mi` |
| `env.LOG_LEVEL` | `DEBUG` | `WARNING` |
| `env.DATABASE_URL` | `postgresql://admin:local_password@postgres:5432/cloudcare` | (from K8s Secret) |
| `databaseSecretName` | (empty) | `patient-service-db-secret` |
| `hpa.enabled` | `false` | `true` |
| `externalSecret.enabled` | `false` | `false` (secret already created manually in Doc 07) |

### audit-service

| Setting | `values-dev.yaml` | `values-prod.yaml` |
|---|---|---|
| `dynamodbEndpointUrl` | `http://dynamodb-local:8000` | (not set — uses real AWS) |
| `awsAccessKeyId` | `local` | (not set — uses IRSA) |
| `awsSecretAccessKey` | `local` | (not set — uses IRSA) |
| `serviceAccount.roleArn` | (not set) | `arn:aws:iam::670794226080:role/cloudcare-k8s-audit-service` |
| `env.LOG_LEVEL` | `DEBUG` | `WARNING` |
| `hpa.enabled` | (default: false) | `true` |

---

## 13. Verify Namespace Isolation

```bash
# Get a shell inside a dev pod
kubectl exec -it deployment/patient-service -n dev -- /bin/sh

# Try to reach a prod service using the short DNS name
# (short name only resolves within the same namespace — this will fail as expected)
curl http://patient-service:8001/health
# this hits the DEV patient-service, not prod — correct

# Try to reach prod using the full cross-namespace DNS name
curl http://patient-service.prod.svc.cluster.local:8001/health
# This should TIME OUT because the NetworkPolicy blocks it
# "Connection refused" or timeout = NetworkPolicy is working

exit
```

---

## 14. Dev vs Prod Commands at a Glance

```bash
# See all pods in dev
kubectl get pods -n dev

# See all pods in prod
kubectl get pods -n prod

# See Helm releases in dev
helm list -n dev

# See Helm releases in prod
helm list -n prod

# Check HPA (only in prod)
kubectl get hpa -n prod

# Check ingress — shows the ALB DNS name
kubectl get ingress -n prod
# NAME                CLASS   HOSTS   ADDRESS                              PORTS
# cloudcare-ingress   alb     *       k8s-prod-xxx.ap-south-1.elb.amazonaws.com   80

# Watch pod logs live
kubectl logs -f deployment/patient-service -n prod

# Roll back patient-service in prod to revision 1
helm rollback patient-service 1 -n prod

# Full rollout status (wait until deployment is healthy)
kubectl rollout status deployment/patient-service -n prod
```

---

## ✅ Final Project Checklist

This is the full "done" definition for the entire CloudCare-K8s project.

### Infrastructure
- [ ] `terraform apply` in `terraform/bootstrap` — S3 state bucket created
- [ ] `terraform apply` in `terraform/eks` — cluster running, 2 nodes Ready
- [ ] `terraform apply` in `terraform/platform` — RDS running, ALB controller installed, Metrics Server running

### Cluster setup
- [ ] `kubectl apply -k k8s/overlays/dev` — dev namespace ready
- [ ] `kubectl apply -k k8s/overlays/prod` — prod namespace ready
- [ ] `kubectl create configmap postgres-init --from-file=init.sql=services/init.sql -n dev`

### Dev environment
- [ ] All 4 services deployed to dev namespace with `values-dev.yaml`
- [ ] `kubectl get pods -n dev` — 6 pods Running (4 services + postgres + dynamodb-local)
- [ ] `GET http://<dev-alb>/patients` returns 200

### Prod environment
- [ ] All 4 services deployed to prod namespace with `values-prod.yaml`
- [ ] `kubectl get pods -n prod` — 8 pods Running (2 replicas each)
- [ ] `kubectl get hpa -n prod` — all 4 HPAs showing targets
- [ ] `GET http://<prod-alb>/patients` returns 200

### CI/CD (Doc 06)
- [ ] Push change to `patient-service/` → pipeline runs automatically
- [ ] Dev deploys automatically, prod waits for approval
- [ ] Approve in GitHub → prod updates, zero downtime rolling deploy

### Observability (Doc 09)
- [ ] Prometheus, Grafana, Loki running in `monitoring` namespace
- [ ] `kubectl get pods -n monitoring` — all Running
- [ ] Grafana at `localhost:3000` — Kubernetes dashboards visible
- [ ] `http://localhost:9090/targets` — all 4 services showing as UP
- [ ] RED dashboard built for patient-service
- [ ] At least one alert rule visible in `http://localhost:9090/alerts`

### Teardown (cost discipline)
- [ ] `terraform destroy` in `terraform/platform` — ALB controller, RDS deleted
- [ ] `terraform destroy` in `terraform/eks` — cluster, nodes, VPC deleted
- [ ] AWS Console Billing → no unexpected charges

---

## 15. The Interview Story

Practise saying this out loud until it's fluent:

> *"CloudCare v1 was a monolithic FastAPI app deployed on an EC2 Auto Scaling Group
> behind an ALB. I built it to learn Terraform, VPC networking, IAM, RDS, and
> GitHub Actions — the fundamentals every DevOps role expects.
>
> Once I was comfortable with those, I re-platformed it onto Kubernetes to understand
> how modern teams actually operate containerised workloads. I split the monolith into
> four independent microservices: patient, appointment, audit, and notification. Each
> service has its own ECR repository, Helm chart, and GitHub Actions pipeline. A change
> to patient-service deploys only patient-service — the other three are untouched.
>
> The cluster is EKS, provisioned with Terraform across three stacks: bootstrap, eks,
> and platform. The VPC has three layers — public subnets for worker nodes and the ALB,
> private subnets for internal load balancers, and database subnets for RDS.
>
> I run dev and prod as namespaces in the same cluster to keep costs down. Dev uses a
> postgres pod and DynamoDB Local instead of real AWS services. Prod uses RDS and real
> DynamoDB. Network policies block dev pods from calling prod services. Secrets come
> from AWS Secrets Manager via the External Secrets Operator — they never touch Git.
> The audit and notification services get AWS credentials through IRSA — the pod's
> service account assumes an IAM role; no access keys are stored anywhere.
>
> HPA scales each service independently. The observability stack is Prometheus for
> metrics, Grafana for dashboards, and Loki for logs. I have RED dashboards per service
> and alert rules for error rate, crash-looping, HPA saturation, and latency.
>
> The whole thing costs about ninety dollars a month when EKS is running, and near zero
> when it's torn down. I can destroy and recreate the entire stack in about fifteen
> minutes with Terraform. That's the practice I care about — infrastructure as code that
> you can trust, not manual console clicks you can't reproduce."*

---

**You have completed all 10 phases of CloudCare-K8s.**
