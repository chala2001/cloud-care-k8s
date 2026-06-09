# 05 — EKS Cluster with Terraform

> **Goal of this doc:** provision a production-grade Kubernetes cluster on AWS using
> Terraform. Understand the 3-stack model, what each stack builds, how to connect
> kubectl to the cluster, and — critically — how to keep costs near zero.

> ⚠️ **Cost warning:** EKS control plane costs **~$0.10/hour (~$2.40/day)** from the
> moment you run `terraform apply` in the `eks` stack. There is no free tier.
> Always run `terraform destroy` when done for the day.

---

## 1. What Is EKS?

**Amazon Elastic Kubernetes Service (EKS)** is AWS's managed Kubernetes offering. It
means AWS runs and manages the Kubernetes **control plane** (the API server, etcd,
scheduler) for you. You don't set up these components — you just pay ~$0.10/hour
for them to exist.

You are responsible for the **worker nodes** — the EC2 instances where your pods
actually run. In our case these are `t3.micro` instances (free-tier eligible).

```
EKS Cluster
├── Control Plane (AWS-managed, ~$0.10/hr)
│   ├── API Server (handles kubectl commands)
│   ├── etcd (stores all cluster state)
│   └── Scheduler (decides which node runs each pod)
│
└── Worker Nodes (EC2 t3.micro — you manage these)
    ├── node-1 (ap-south-1a)  ← pods run here
    └── node-2 (ap-south-1b)  ← pods run here
```

---

## 2. The 3-Stack Model

This project uses **three Terraform stacks**, each with its own remote state key.
This is the same per-stack isolation pattern from CloudCare v1.

| Stack | State key | What it builds | Cost |
|---|---|---|---|
| `bootstrap` | `bootstrap/terraform.tfstate` | S3 state bucket + DynamoDB lock | ~cents/mo |
| `eks` | `eks/terraform.tfstate` | VPC, EKS cluster, node group, OIDC, ECR | ⚠️ ~$73/mo if left on |
| `platform` | `platform/terraform.tfstate` | RDS, Secrets Manager, ALB Ingress Controller, ESO, S3, CloudFront | ⚠️ RDS hours |

Stacks read each other via `terraform_remote_state`:
- `platform` reads VPC and cluster info from `eks` state
- `eks` reads the state bucket name from `bootstrap` state

---

## 3. Bootstrap Stack

Identical in purpose to CloudCare v1 — creates the S3 bucket and DynamoDB table for
remote state. Run this **once and leave it running** (costs cents/month).

`terraform/bootstrap/main.tf`:
```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true   # Protects against accidental deletion
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "lock" {
  name         = "${var.state_bucket_name}-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" { value = aws_s3_bucket.state.bucket }
output "lock_table_name"   { value = aws_dynamodb_table.lock.name }
```

Apply:
```bash
export AWS_PROFILE=cloudcare-k8s
export AWS_REGION=ap-south-1

cd terraform/bootstrap
terraform init
terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"
```

---

## 4. EKS Stack

This is the most complex stack. It builds the entire network and Kubernetes cluster.

`terraform/eks/backend.tf`:
```hcl
terraform {
  backend "s3" {
    bucket         = "cloudcare-k8s-tfstate-<your-account-id>"
    key            = "eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-k8s-tfstate-<your-account-id>-lock"
    encrypt        = true
  }
}
```

### 4.1 VPC (`terraform/eks/vpc.tf`)

Same 3-tier VPC as CloudCare v1 — but now the "app" tier hosts EKS worker nodes
instead of EC2 instances in an ASG.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true    # required for EKS
  enable_dns_support   = true    # required for EKS

  tags = {
    Name = "cloudcare-k8s-vpc"
    # These tags are required for the AWS ALB Ingress Controller to discover subnets:
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# Public subnets — ALB and NAT instance live here
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "cloudcare-k8s-public-${count.index}"
    # Required tag for ALB Ingress Controller to find public subnets:
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# Private subnets — EKS worker nodes live here
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "cloudcare-k8s-private-${count.index}"
    # Required for ALB Ingress Controller to find private subnets:
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}
```

> 🧠 **Why do subnets need Kubernetes tags?** The AWS ALB Ingress Controller
> reads these tags to know which subnets to create load balancers in. Without them,
> the controller can't create an ALB and your Ingress resource won't work.

### 4.2 NAT Instance (`terraform/eks/nat.tf`)

Same as v1 — a `t3.micro` acting as NAT (free tier) instead of a NAT Gateway ($32/mo).
Worker nodes in private subnets need outbound internet to pull Docker images from ECR.

```hcl
data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-*"]
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false   # required for NAT to work

  tags = { Name = "cloudcare-k8s-nat" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}
```

### 4.3 EKS Cluster (`terraform/eks/eks.tf`)

```hcl
resource "aws_eks_cluster" "main" {
  name     = "cloudcare-k8s"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true    # kubectl works from within the VPC
    endpoint_public_access  = false   # don't expose the K8s API publicly
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "cloudcare-k8s-workers"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id    # workers in private subnets
  instance_types  = ["t3.micro"]                # free tier eligible

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  # IMDSv2 required — prevents SSRF-based credential theft
  launch_template {
    id      = aws_launch_template.workers.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}

resource "aws_launch_template" "workers" {
  name_prefix = "cloudcare-k8s-workers-"

  metadata_options {
    http_tokens   = "required"   # IMDSv2 only
    http_endpoint = "enabled"
  }
}
```

### 4.4 OIDC Provider (`terraform/eks/oidc.tf`)

This is critical for two things:
1. **IRSA** (IAM Roles for Service Accounts) — lets pods assume IAM roles
2. **GitHub Actions OIDC** — lets CI authenticate to AWS without stored keys

```hcl
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Also create the GitHub OIDC provider for keyless CI
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

### 4.5 ECR Repositories (`terraform/eks/ecr.tf`)

One ECR repository per microservice:

```hcl
locals {
  services = ["patient-service", "appointment-service", "audit-service", "notification-service"]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "cloudcare-k8s-${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

`scan_on_push = true` means ECR runs a vulnerability scan every time you push an image.
Free and catches known CVEs automatically.

---

## 5. Platform Stack

Runs **after** the EKS stack. Reads EKS outputs (VPC ID, cluster name, subnet IDs)
via `terraform_remote_state`.

Key resources provisioned by `terraform/platform/`:

**RDS PostgreSQL** (`rds.tf`):
```hcl
resource "aws_db_instance" "main" {
  identifier        = "cloudcare-k8s-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"    # free tier eligible
  allocated_storage = 20

  db_name  = "cloudcare"
  username = "admin"
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false    # single-AZ to stay in free tier
  publicly_accessible    = false    # private subnet only

  skip_final_snapshot = true        # for easy destroy in lab
}
```

**Secrets Manager** (`secrets.tf`):
```hcl
resource "aws_secretsmanager_secret" "patient_db" {
  name = "cloudcare-k8s/patient-service/db"
}

resource "aws_secretsmanager_secret_version" "patient_db" {
  secret_id = aws_secretsmanager_secret.patient_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://patient_svc:${random_password.patient_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
  })
}
```

**ALB Ingress Controller** (via Helm, managed by Terraform):
```hcl
resource "helm_release" "alb_ingress_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set { name = "clusterName"; value = "cloudcare-k8s" }
  set { name = "serviceAccount.create"; value = "true" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.alb_controller.arn }
}
```

---

## 6. Apply the Stacks

### Step 1: Bootstrap (one-time)

```bash
cd terraform/bootstrap
terraform init
terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"
```

### Step 2: EKS cluster

```bash
cd terraform/eks
terraform init
terraform apply
```

This takes **10–15 minutes** — EKS cluster creation is slow. Watch the output.

After apply:
```bash
# Configure kubectl to use the new cluster
aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1

# Verify connectivity
kubectl get nodes
# NAME                                         STATUS   ROLES    AGE   VERSION
# ip-10-0-10-45.ap-south-1.compute.internal   Ready    <none>   5m    v1.30.x
# ip-10-0-11-23.ap-south-1.compute.internal   Ready    <none>   5m    v1.30.x
```

Two nodes in `Ready` status = your cluster is healthy.

### Step 3: Platform resources

```bash
cd terraform/platform
terraform init
terraform apply
```

---

## 7. Deploy Services to EKS

Now deploy using Helm with prod values:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1

# Login to ECR
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Build, tag, and push each service
for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  ( cd services/$svc && docker build -t "$ECR:latest" . && docker push "$ECR:latest" )
done

# Deploy with Helm
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.repository="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc" \
    --set image.tag=latest \
    --namespace prod --create-namespace
done

kubectl get pods -n prod
```

---

## 8. Destroy When Done (IMPORTANT)

```bash
# Remove Helm releases first (so Kubernetes doesn't try to delete ALBs during destroy)
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod 2>/dev/null || true
done

# Destroy in reverse dependency order
cd terraform/platform && terraform destroy -auto-approve
cd terraform/eks      && terraform destroy -auto-approve
# Leave bootstrap running — it costs cents and holds all state
```

Set a reminder on your phone if you need to. **Forgetting to destroy = unexpected bill.**

---

## ✅ Checkpoint

You should be able to answer:

- What is the difference between the EKS control plane and worker nodes?
- Why do EKS subnets need `kubernetes.io/role/elb` tags?
- What does the OIDC provider enable?
- Why do we use a NAT instance instead of NAT Gateway?
- Why is `endpoint_public_access = false` a good practice?
- What is the first thing you do after an EKS lab session?

Next: **[06 — CI/CD Pipelines](06-cicd.md)** — automate the build, test, push, and
deploy flow so every code change triggers its own pipeline.
