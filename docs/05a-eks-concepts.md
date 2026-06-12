# 05a — EKS + Terraform: Concepts and Mental Model

> **Goal:** understand what EKS is, why we use 3 Terraform stacks, how VPC
> networking works for Kubernetes, and what OIDC/IRSA means — before writing
> a single line of Terraform.
>
> ⚠️ **Cost warning:** EKS costs ~$0.10/hour the moment it exists.
> Understand the cost model completely before running `terraform apply`.

---

## 1. What is EKS?

On minikube, Kubernetes ran on your laptop as a single virtual machine.
In production, Kubernetes has two parts with very different responsibilities:

```
Kubernetes = Control Plane + Worker Nodes

Control Plane (the brain):
  ├── API Server    — receives your kubectl commands
  ├── etcd          — stores ALL cluster state (what should be running, etc.)
  ├── Scheduler     — decides which node a new pod runs on
  └── Controller    — watches cluster state and fixes it (the self-healing loop)

Worker Nodes (the muscle):
  └── EC2 instances that actually run your pods
```

Running the control plane yourself is hard — etcd needs high availability, the API
server needs TLS, the scheduler needs careful configuration. This can take weeks to
get right and weeks more to maintain.

**EKS (Elastic Kubernetes Service) means AWS runs the control plane for you.**

```
Without EKS (self-managed):               With EKS:
  You manage: everything                    AWS manages: control plane
  Your time: weeks of setup                 You manage: worker nodes only
  Risk: etcd corruption, API downtime       Cost: ~$0.10/hour
```

You still manage the **worker nodes** — the EC2 instances where your pods run.
For this project: 2× `t3.micro` (free-tier eligible).

```
EKS Cluster "cloudcare-k8s"
│
├── Control Plane (AWS-managed, ~$0.10/hr)
│   ├── API Server (receives: kubectl apply, kubectl get pods, etc.)
│   ├── etcd (remembers: "patient-service should have 2 replicas")
│   └── Scheduler (decides: "put this pod on node-1")
│
└── Node Group (your EC2 instances)
    ├── node-1  t3.micro  ap-south-1a  ← patient-service pod runs here
    └── node-2  t3.micro  ap-south-1b  ← appointment-service pod runs here
```

---

## 2. The 3-Stack model — why separate stacks?

Everything could be in one Terraform stack. But there's a better pattern:
split resources by **how often they change** and **what depends on what**.

```
Stack 1: bootstrap           Stack 2: eks              Stack 3: platform
─────────────────────        ────────────────────       ─────────────────────
What: S3 + DynamoDB          What: VPC + EKS            What: RDS + Secrets +
      for Terraform state          + nodes + OIDC              ALB + ESO

Cost: cents/month            Cost: ~$73/month           Cost: ~$15/month (RDS)

Lifecycle: permanent         Lifecycle: destroy          Lifecycle: destroy
(never destroy this)         when done for the day      when done for the day

Why separate: if this        Why separate: networking    Why separate: platform
breaks, you lose ALL         and cluster change          reads cluster outputs.
Terraform state.             independently of apps.      Apps change more often.
```

Stacks read each other via `terraform_remote_state`:

```
bootstrap outputs → eks reads: state bucket name
eks outputs       → platform reads: VPC ID, subnet IDs, cluster name, OIDC ARN
```

This means: if you change VPC settings (eks stack), platform automatically
picks up the new subnet IDs next time it runs — no manual copying.

---

## 3. VPC for Kubernetes — what's different from v1

In CloudCare v1, the VPC had:
- Public subnets → ALB, NAT instance
- Private subnets → EC2 app servers, RDS

In CloudCare-k8s, the structure is the same but the private subnets now hold
**EKS worker nodes** instead of individual EC2 app servers.

```
ap-south-1 VPC (10.0.0.0/16)
│
├── Public Subnet A (10.0.0.0/24)  — ap-south-1a  ┐ Layer 1: public
├── Public Subnet B (10.0.1.0/24)  — ap-south-1b  ┘ NAT instance, ALB
│
├── Private Subnet A (10.0.10.0/24) — ap-south-1a ┐ Layer 2: app
├── Private Subnet B (10.0.11.0/24) — ap-south-1b ┘ EKS nodes (pods run here)
│
├── DB Subnet A (10.0.20.0/24) — ap-south-1a       ┐ Layer 3: database
└── DB Subnet B (10.0.21.0/24) — ap-south-1b       ┘ RDS only — no internet access
```

6 subnets total — 2 per layer, same 3-layer pattern as cloud-care v1.

### Why 2 subnets in 2 Availability Zones?

EKS **requires** at least 2 subnets in 2 different Availability Zones.
If AWS has a data centre failure in ap-south-1a, your pods on node-2 (in ap-south-1b)
keep running. This is **high availability**.

### The special Kubernetes subnet tags

EKS subnets need special tags that don't exist in a regular VPC:

```hcl
# On public subnets:
"kubernetes.io/role/elb" = "1"

# On private subnets:
"kubernetes.io/role/internal-elb" = "1"

# On ALL subnets:
"kubernetes.io/cluster/cloudcare-k8s" = "shared"
```

**Why?** The AWS ALB Ingress Controller runs as a pod inside your cluster. When you
apply an Ingress YAML, that pod calls the AWS API to create an ALB. But how does it
know which subnets to use? It reads these tags. Without them, Ingress resources
silently fail to create any load balancer.

---

## 4. OIDC Provider — the identity bridge

This is one of the most important concepts in modern AWS + Kubernetes.

**The problem:** your pods need to call AWS services (DynamoDB, SES, Secrets Manager).
To call AWS, you need credentials. You could put AWS keys in the pod as env vars —
but then anyone who can read the pod's config can steal those keys.

**OIDC solves this.** It lets a pod **prove its identity** to AWS without any stored
credentials.

Here is how it works:

```
1. When EKS starts, it creates an OIDC issuer URL:
   https://oidc.eks.ap-south-1.amazonaws.com/id/ABC123

2. You register this URL with AWS IAM as a trusted identity provider
   (this is what terraform/eks/oidc.tf does)

3. You create an IAM Role with a trust policy that says:
   "Trust identities from this OIDC issuer IF the ServiceAccount is
    named audit-service in namespace prod"

4. You annotate the Kubernetes ServiceAccount:
   eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/cloudcare-k8s-audit-service

5. When the audit-service pod starts, it automatically gets a temporary token
   that proves it is "audit-service in namespace prod"

6. The pod exchanges this token with AWS STS for temporary AWS credentials
   (valid for 15 minutes, auto-refreshed — no storage needed)
```

This mechanism is called **IRSA (IAM Roles for Service Accounts)**. You will
implement it in detail in Doc 07.

**OIDC is also used for GitHub Actions** — your CI pipeline proves it's running
for your specific repo and gets temporary AWS credentials. No stored access keys
in GitHub Secrets.

---

## 5. ECR — your private Docker registry

ECR (Elastic Container Registry) is AWS's Docker image registry, like Docker Hub
but private and inside your AWS account.

```
Local development:
  docker build -t patient-service:local .
  images live on your laptop / in minikube

Production:
  docker build -t 123456789.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-k8s-patient-service:a3f8b2c .
  docker push 123456789.dkr.ecr.ap-south-1.amazonaws.com/...
  EKS nodes pull from ECR when starting pods
```

One ECR repository per microservice:
```
cloudcare-k8s-patient-service      ← patient-service images
cloudcare-k8s-appointment-service  ← appointment-service images
cloudcare-k8s-audit-service
cloudcare-k8s-notification-service
```

**scan_on_push = true** — every pushed image is automatically scanned for known
security vulnerabilities (CVEs). Free. You see results in the AWS console.

EKS nodes can pull from ECR because the node IAM role has `AmazonEC2ContainerRegistryReadOnly`
policy. No separate authentication needed.

---

## 6. The cost model — read before applying

```
Resource                    Cost                When it starts
─────────────────────────── ─────────────────── ──────────────────
EKS control plane           $0.10/hour          terraform apply (eks)
2× t3.micro nodes           ~$0.023/hour each   terraform apply (eks)
NAT instance (t3.micro)     ~$0.023/hour        terraform apply (eks)
RDS db.t3.micro             ~$0.017/hour        terraform apply (platform)
                            ───────────────
Total running               ~$0.18/hour
                            ~$4.40/day
                            ~$133/month if left on 24/7

S3 state bucket             ~$0.01/month        permanent (leave running)
DynamoDB lock table         free (pay per req)  permanent (leave running)
ECR storage                 ~$0.10/GB/month     leave running (negligible)
```

**The discipline:** only run EKS when actively learning. Destroy at the end
of every session.

```bash
# START of session (takes 10-15 min)
cd terraform/eks && terraform apply

# END of session (takes 5-10 min)
cd terraform/platform && terraform destroy -auto-approve
cd terraform/eks      && terraform destroy -auto-approve
# bootstrap stays — it costs cents and holds your Terraform state
```

Set a phone alarm. Never leave EKS running overnight.

---

## 7. What each Terraform file in each stack does

### bootstrap/
```
main.tf      → creates S3 bucket (stores all Terraform state files)
             → creates DynamoDB table (prevents two people applying at the same time)
```

### eks/
```
backend.tf   → tells Terraform to store THIS stack's state in S3 (from bootstrap)
vpc.tf       → VPC, public subnets, private subnets, internet gateway, route tables
nat.tf       → NAT instance + security group + route (private subnets → internet)
eks.tf       → EKS cluster IAM role + cluster + node group IAM role + node group + launch template
oidc.tf      → EKS OIDC provider + GitHub OIDC provider + GitHub deploy IAM role
ecr.tf       → 4 ECR repositories (one per microservice)
outputs.tf   → exports VPC ID, subnet IDs, cluster name, OIDC ARN for platform stack
```

### platform/
```
backend.tf       → S3 state storage for this stack
remote_state.tf  → reads eks stack outputs (VPC ID, subnets, cluster name)
rds.tf           → RDS PostgreSQL db.t3.micro in private subnets
secrets.tf       → Secrets Manager secrets (one per service's DATABASE_URL)
alb.tf           → ALB Ingress Controller (Helm release managed by Terraform)
eso.tf           → External Secrets Operator (Helm release managed by Terraform)
metrics.tf       → Metrics Server (needed for HPA to read CPU metrics)
```

---

## 8. How it connects to the rest of the project

```
terraform/bootstrap  →  creates state storage
       ↓
terraform/eks        →  creates cluster where pods run
       ↓
terraform/platform   →  creates RDS, secrets, ALB controller
       ↓
helm upgrade         →  deploys your 4 microservices into the cluster
       ↓
GitHub Actions       →  automates the helm upgrade on every code push (Doc 06)
       ↓
IRSA                 →  gives pods secure AWS credentials (Doc 07)
       ↓
Prometheus/Grafana   →  monitors the running pods (Doc 09)
```

---

**You understand the concepts. Go to [05b — EKS Practice](05b-eks-practice.md)
to read every line of every Terraform file.**
