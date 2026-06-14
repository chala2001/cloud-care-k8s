# 05b — EKS Practice: Every Terraform File, Every Line

> **Read 05a first.** This doc writes every Terraform file for all 3 stacks
> with every line explained, then applies them in the correct order.
>
> ⚠️ **Cost reminder:** EKS = ~$0.10/hr (~$2.40/day). Destroy at the end of every session.

---

## Issues encountered during this phase (and how we solved them)

Real deployments hit real problems. These are the exact issues we hit and how we fixed them —
so if you see the same error, you know what to do immediately.

| Issue | Error | Fix |
|-------|-------|-----|
| **NodeCreationFailure** | Nodes stuck in `NodeCreationFailure` for 33+ min, never joined the cluster | Moved node group to **public subnets** (direct IGW) — DIY NAT instance couldn't reliably route EKS API endpoint and ECR traffic from private subnets |
| **OOMKilled pods** | Pods killed immediately, `kubectl describe pod` shows `OOMKilled` | Changed node instance type from `t3.micro` to **`t3.small`** — t3.micro had too little RAM for EKS system pods + app pods |
| **ALB controller CrashLoopBackOff** | `EC2MetadataError: failed to fetch VPC ID: status code: 401` | Added `vpcId` explicitly to the Helm `set` values in `alb.tf` — IMDSv2 requires a token that the ALB controller pod can't get without extra setup |
| **Stale Terraform state lock** | `Error acquiring the state lock` from a previous crashed apply | `terraform force-unlock -force <lock-id>` — the lock ID is shown in the error message |
| **Secrets Manager deletion queue** | `InvalidRequestException: secret already scheduled for deletion` | Added `recovery_window_in_days = 0` to both `aws_secretsmanager_secret` resources in `secrets.tf` |

---

## 1. Create the directory structure

```bash
# Create all Terraform stack directories
mkdir -p /home/chalaka/cloud-care-both/cloud-care-k8s/terraform/bootstrap
mkdir -p /home/chalaka/cloud-care-both/cloud-care-k8s/terraform/eks
mkdir -p /home/chalaka/cloud-care-both/cloud-care-k8s/terraform/platform

cd /home/chalaka/cloud-care-both/cloud-care-k8s
```

---

## 2. Stack 1: bootstrap

**Purpose:** create the S3 bucket and DynamoDB table that store all Terraform state.
Run this **once and leave it running** (costs cents per month).

`terraform/bootstrap/main.tf`:
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"    # use any 5.x version of the AWS provider
    }
  }
  # No backend block here — bootstrap stores its own state locally.
  # All OTHER stacks store their state in the S3 bucket this creates.
}

provider "aws" {
  region = "ap-south-1"    # Mumbai — change if you use a different region
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
  # Passed via: terraform apply -var="state_bucket_name=..."
  # S3 bucket names must be globally unique across ALL AWS accounts worldwide
}

# ── S3 bucket to store all Terraform state files ──────────────────────────────
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true    # terraform destroy will FAIL if you try to delete this
    # this protects against accidentally destroying all your Terraform state
    # if that happens, Terraform loses track of what it created → very hard to recover
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"    # keeps every version of every state file
    # if a bad apply corrupts your state, you can roll back to an older version
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"    # encrypt state files at rest
      # state files contain sensitive data (DB passwords, resource IDs)
    }
  }
}

# ── DynamoDB table for state locking ──────────────────────────────────────────
resource "aws_dynamodb_table" "lock" {
  name         = "${var.state_bucket_name}-lock"    # same name as bucket + "-lock"
  billing_mode = "PAY_PER_REQUEST"    # no fixed cost — pay only when locks happen
  hash_key     = "LockID"             # DynamoDB needs a primary key — Terraform uses "LockID"

  attribute {
    name = "LockID"
    type = "S"    # S = String type
  }
  # When two people run terraform apply at the same time, one writes a lock entry here
  # The other sees the lock and waits. Prevents state corruption.
}

# ── Outputs (other stacks can read these) ─────────────────────────────────────
output "state_bucket_name" { value = aws_s3_bucket.state.bucket }
output "lock_table_name"   { value = aws_dynamodb_table.lock.name }
```

**Apply bootstrap (one-time only):**
```bash
# Set your AWS credentials
export AWS_PROFILE=cloudcare-k8s    # your AWS CLI profile
export AWS_REGION=ap-south-1

# Move to bootstrap directory
cd terraform/bootstrap

# Download the AWS provider plugin
terraform init

# Get your AWS account ID automatically and use it in the bucket name
# This guarantees the bucket name is unique (your account ID is unique)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create the S3 bucket and DynamoDB lock table
terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-${ACCOUNT_ID}"

# Save the bucket name — you'll need it in the next stack's backend.tf
echo "State bucket: cloudcare-k8s-tfstate-${ACCOUNT_ID}"
```

---

## 3. Stack 2: eks

### terraform/eks/backend.tf

```hcl
terraform {
  backend "s3" {
    bucket         = "cloudcare-k8s-tfstate-<your-account-id>"  # replace with your bucket name
    key            = "eks/terraform.tfstate"    # path inside the bucket for THIS stack's state
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-k8s-tfstate-<your-account-id>-lock"
    encrypt        = true    # encrypt state at rest (matches bucket encryption)
  }

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
    # tls provider is needed to read the EKS OIDC certificate thumbprint
  }
}

provider "aws" {
  region = "ap-south-1"
}

data "aws_availability_zones" "available" {}
# reads the list of AZs in ap-south-1 at plan time
# used in subnet resources below: data.aws_availability_zones.available.names[0]
```

### terraform/eks/vpc.tf

```hcl
# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"    # 65,536 IP addresses — more than enough
  enable_dns_hostnames = true              # required for EKS: nodes need DNS hostnames
  enable_dns_support   = true             # required for EKS: internal DNS resolution

  tags = {
    Name = "cloudcare-k8s-vpc"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
    # this tag tells the ALB Ingress Controller this VPC belongs to our cluster
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id    # attach to our VPC
  # the IGW is the door between the VPC and the public internet
  # public subnets route outbound traffic through this
  tags = { Name = "cloudcare-k8s-igw" }
}

# ── Public Subnets (2 — one per AZ) ──────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = 2    # create 2 copies of this resource (one per AZ)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  # cidrsubnet carves out smaller subnets from the VPC CIDR
  # count.index = 0 → 10.0.0.0/24
  # count.index = 1 → 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # count.index = 0 → ap-south-1a
  # count.index = 1 → ap-south-1b
  map_public_ip_on_launch = true    # EC2 instances in this subnet get a public IP automatically

  tags = {
    Name = "cloudcare-k8s-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
    # tells ALB Ingress Controller: "create internet-facing ALBs in these subnets"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# ── Private Subnets / App Layer (2 — one per AZ) ─────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  # count.index = 0 → 10.0.10.0/24
  # count.index = 1 → 10.0.11.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "cloudcare-k8s-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
    # tells ALB Ingress Controller: "create internal ALBs in these subnets"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# ── Database Subnets (2 — one per AZ) ────────────────────────────────────────
resource "aws_subnet" "database" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 20)
  # count.index = 0 → 10.0.20.0/24
  # count.index = 1 → 10.0.21.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # separate layer: only RDS lives here — EKS nodes cannot reach it without SG rules

  tags = {
    Name = "cloudcare-k8s-db-${count.index}"
  }
}

# ── Route Tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"             # all outbound traffic
    gateway_id = aws_internet_gateway.main.id    # goes through the Internet Gateway
  }
  tags = { Name = "cloudcare-k8s-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # No internet route — DB subnets only. EKS nodes are in public subnets with direct IGW access.
  tags = { Name = "cloudcare-k8s-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB subnets use the same private route table — no internet access needed
resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.private.id
}
```

> **Why no NAT instance?** The original design placed EKS nodes in private subnets and
> used a DIY NAT instance (t3.micro) for outbound internet access to ECR and the EKS API.
> This caused `NodeCreationFailure` — nodes timed out after 33+ minutes waiting to join
> the cluster. The NAT instance wasn't routing traffic reliably enough. The fix was to
> move nodes to the public subnets where they have direct IGW access. Security is
> maintained by Security Groups — no SSH ports are open, and EKS-managed security groups
> control pod-level traffic. There is no `nat.tf` in this project.

### terraform/eks/eks.tf

```hcl
# ── IAM Role for the EKS Control Plane ───────────────────────────────────────
# EKS needs permission to manage AWS resources on your behalf (ENIs, security groups)
resource "aws_iam_role" "eks_cluster" {
  name = "cloudcare-k8s-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # allows the EKS service itself to assume this role
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  # AWS-managed policy — gives EKS everything it needs to manage the cluster
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = "cloudcare-k8s"                    # cluster name — used in kubectl commands
  role_arn = aws_iam_role.eks_cluster.arn       # the IAM role above
  version  = "1.30"                             # Kubernetes version

  vpc_config {
    subnet_ids = concat(
      aws_subnet.public[*].id,    # [*] = all items in the list
      aws_subnet.private[*].id    # EKS needs both public and private subnet IDs
    )
    endpoint_private_access = true    # kubectl works from inside the VPC
    endpoint_public_access  = false   # the K8s API server is NOT reachable from the internet
    security_group_ids = [aws_security_group.eks_cluster.id]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
  # Terraform must attach the IAM policy BEFORE creating the cluster
}

# ── Security Group for EKS Cluster ───────────────────────────────────────────
resource "aws_security_group" "eks_cluster" {
  name   = "cloudcare-k8s-cluster-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]    # cluster can reach anything outbound
  }
}

# ── IAM Role for Worker Nodes ─────────────────────────────────────────────────
resource "aws_iam_role" "eks_node" {
  name = "cloudcare-k8s-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }    # EC2 instances assume this role
      Action    = "sts:AssumeRole"
    }]
  })
}

# 3 policies worker nodes need:
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  # allows nodes to join the cluster and receive pod assignments
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  # allows the VPC CNI plugin to assign pod IP addresses from the VPC CIDR
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  # allows nodes to pull Docker images from ECR
}

# ── Launch Template (IMDSv2) ──────────────────────────────────────────────────
resource "aws_launch_template" "workers" {
  name_prefix = "cloudcare-k8s-workers-"

  metadata_options {
    http_tokens   = "required"    # force IMDSv2 (token-based metadata access)
    http_endpoint = "enabled"
    # IMDSv2 prevents SSRF attacks from stealing node credentials
    # Without this, a malicious pod could call 169.254.169.254 and steal the node's IAM role
  }
}

# ── Node Group (the EC2 instances that run pods) ──────────────────────────────
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "cloudcare-k8s-workers"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.public[*].id    # public subnets — nodes get public IPs, direct IGW access
  # ↑ originally aws_subnet.private[*].id but caused NodeCreationFailure (see Issues above)
  instance_types  = ["t3.small"]    # t3.small (2 GiB RAM) — t3.micro was OOMKilled

  scaling_config {
    desired_size = 2    # start with 2 nodes
    min_size     = 2    # never go below 2 (HA: tolerate one node failure)
    max_size     = 4    # allow up to 4 during heavy load
  }

  launch_template {
    id      = aws_launch_template.workers.id
    version = "$Latest"    # always use the latest version of the launch template
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
  # all 3 IAM policies must be attached before nodes can join the cluster
}
```

### terraform/eks/oidc.tf

```hcl
# ── EKS OIDC Provider ─────────────────────────────────────────────────────────
# Enables IRSA: pods can assume IAM roles without stored credentials (Doc 07)

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
  # reads the TLS certificate of EKS's OIDC issuer endpoint
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]    # AWS STS is the audience
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
  # the URL uniquely identifies your cluster's OIDC issuer
  # format: https://oidc.eks.ap-south-1.amazonaws.com/id/UNIQUE_ID
}

# ── GitHub OIDC Provider ──────────────────────────────────────────────────────
# Enables keyless GitHub Actions authentication — no stored AWS keys in GitHub

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  # GitHub's well-known thumbprint — doesn't change
}

# ── IAM Role for GitHub Actions ───────────────────────────────────────────────
resource "aws_iam_role" "github_deploy" {
  name = "cloudcare-k8s-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:your-github-username/cloud-care-k8s:*"
          # only YOUR repo can assume this role — forks cannot
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "cloudcare-k8s-github-deploy-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",           # login to ECR
          "ecr:BatchCheckLayerAvailability",     # push images
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]       # get kubeconfig for kubectl
        Resource = "arn:aws:eks:ap-south-1:*:cluster/cloudcare-k8s"
      }
    ]
  })
}
```

### terraform/eks/ecr.tf

```hcl
locals {
  services = [
    "patient-service",
    "appointment-service",
    "audit-service",
    "notification-service"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)
  # for_each creates one resource per item in the set

  name                 = "cloudcare-k8s-${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true    # automatically scan every pushed image for CVE vulnerabilities
  }
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}
```

### terraform/eks/outputs.tf

```hcl
# These outputs are read by the platform stack via terraform_remote_state
output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.database[*].id
  # platform stack uses this for the RDS subnet group
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
  # platform stack uses this to create IRSA roles for each microservice
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}
```

---

## 4. Stack 3: platform

### terraform/platform/remote_state.tf

```hcl
# Read outputs from the eks stack — so we know the VPC, subnets, and cluster name
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "cloudcare-k8s-tfstate-<your-account-id>"
    key    = "eks/terraform.tfstate"    # location of the eks stack's state file
    region = "ap-south-1"
  }
}
```

### terraform/platform/providers.tf

```hcl
# Note: Helm provider v3 uses "kubernetes = {}" assignment syntax (not a block)
terraform {
  backend "s3" {
    bucket         = "cloudcare-k8s-tfstate-<your-account-id>"
    key            = "platform/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-k8s-tfstate-<your-account-id>-lock"
    encrypt        = true
  }

  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 6.0" }
    helm   = { source = "hashicorp/helm",   version = "~> 3.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = "ap-south-1"
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "helm" {
  kubernetes = {    # Helm v3: assignment syntax, NOT a block like "kubernetes { ... }"
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

data "aws_eks_cluster" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}
```

### terraform/platform/rds.tf

```hcl
# ── Subnet Group: which subnets RDS can use ───────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "cloudcare-k8s-db"
  subnet_ids = data.terraform_remote_state.eks.outputs.db_subnet_ids
  # RDS lives in the dedicated database subnet layer (10.0.20.x, 10.0.21.x)
}

# ── Security Group: who can connect to RDS ───────────────────────────────────
resource "aws_security_group" "rds" {
  name   = "cloudcare-k8s-rds"
  vpc_id = data.terraform_remote_state.eks.outputs.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]    # only pods inside the VPC can connect
    # EKS nodes (public subnets 10.0.0.x, 10.0.1.x) are still inside the VPC
    # this rule allows them to reach RDS in the DB subnets (10.0.20.x, 10.0.21.x)
  }
}

# ── Random password for master DB user ───────────────────────────────────────
resource "random_password" "db_master" {
  length  = 24
  special = false    # no special chars — connection string parsing can misinterpret them
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "cloudcare-k8s-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"    # free tier: 750 hrs/month for 12 months
  allocated_storage = 20               # 20 GB — minimum, free tier includes up to 20 GB

  db_name  = "cloudcare"              # the database to create on first launch
  username = "cloudcare_admin"        # master user (we create schema-specific users manually)
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false    # single-AZ — multi-AZ doubles the cost
  publicly_accessible    = false    # private only — no direct internet access

  skip_final_snapshot = true        # allow terraform destroy without creating a snapshot
}
```

### terraform/platform/secrets.tf

```hcl
# ── Random passwords for service-specific DB users ────────────────────────────
resource "random_password" "patient_db"      { length = 24; special = false }
resource "random_password" "appointment_db"  { length = 24; special = false }

# ── Secrets Manager secrets — one per service ─────────────────────────────────
# Credentials are stored here and pulled into K8s Secrets at deploy time (Doc 07)

resource "aws_secretsmanager_secret" "patient_db" {
  name                    = "cloudcare-k8s/patient-service/db"
  recovery_window_in_days = 0
  # recovery_window_in_days = 0 means force-delete immediately on terraform destroy
  # without this, deleted secrets sit in a 7-day deletion queue
  # if you try to re-apply within those 7 days you get:
  # "InvalidRequestException: already scheduled for deletion"
}

resource "aws_secretsmanager_secret_version" "patient_db" {
  secret_id = aws_secretsmanager_secret.patient_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://patient_svc:${random_password.patient_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
    # patient_svc is the schema-specific postgres user
    # NOTE: this user must be created manually via psql — Terraform doesn't create DB users
    # see Doc 07 for the DB user initialization procedure
  })
}

resource "aws_secretsmanager_secret" "appointment_db" {
  name                    = "cloudcare-k8s/appointment-service/db"
  recovery_window_in_days = 0    # same reason — immediate deletion on destroy
}

resource "aws_secretsmanager_secret_version" "appointment_db" {
  secret_id = aws_secretsmanager_secret.appointment_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://appt_svc:${random_password.appointment_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
  })
}
```

### terraform/platform/alb.tf

```hcl
# The ALB Ingress Controller watches Ingress YAML resources in the cluster
# and creates real AWS Application Load Balancers for them

# IAM role for the ALB controller pod (uses IRSA)
resource "aws_iam_role" "alb_controller" {
  name = "cloudcare-k8s-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.terraform_remote_state.eks.outputs.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${data.terraform_remote_state.eks.outputs.oidc_provider_url}:sub" =
            "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "cloudcare-k8s-alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/alb-policy.json")    # load from local file
  # download: curl -o alb-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
}

# Install the ALB Ingress Controller via Helm (managed by Terraform)
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  # Helm v3: set values as a list of objects (NOT set {} blocks)
  set = [
    { name = "clusterName";                                                      value = data.terraform_remote_state.eks.outputs.cluster_name },
    { name = "serviceAccount.create";                                            value = "true" },
    { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn";       value = aws_iam_role.alb_controller.arn },
    { name = "vpcId";                                                            value = data.terraform_remote_state.eks.outputs.vpc_id },
    # vpcId must be set explicitly because EKS nodes use IMDSv2 (http_tokens=required)
    # the ALB controller tries to discover the VPC ID from IMDS but gets HTTP 401
    # because IMDSv2 requires a session token that the pod can't obtain without extra setup
    # explicitly passing vpcId bypasses the IMDS lookup entirely
  ]
}

# Install Metrics Server (required for HPA to read CPU metrics)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
}
```

---

## 5. Apply in correct order

```bash
# ── STEP 0: If a previous apply crashed and left a lock ───────────────────────
# You'll see: "Error acquiring the state lock" with a Lock ID in the message
# Run this to release it (safe if no other apply is running):
# cd terraform/eks
# terraform force-unlock -force <lock-id-from-error-message>

# ── STEP 1: Bootstrap (one-time, already done) ────────────────────────────────
cd terraform/bootstrap
# Creates the S3 bucket and DynamoDB lock table — run once and never destroy
terraform init && terraform apply \
  -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"

# ── STEP 2: EKS cluster (takes 10–15 minutes) ─────────────────────────────────
cd terraform/eks

# Downloads providers (aws, tls) and connects to the S3 backend
terraform init

# Preview what will be created: VPC, subnets, EKS cluster, node group, OIDC, ECR
terraform plan

# Create the infrastructure — EKS control plane billing starts here (~$0.10/hr)
terraform apply

# ── STEP 3: Connect kubectl to the new cluster ────────────────────────────────
# Writes EKS credentials to ~/.kube/config so kubectl works
aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1

# Verify — nodes will be in public subnets (ip-10-0-0-x or ip-10-0-1-x addresses)
kubectl get nodes
# NAME                                        STATUS   ROLES    AGE   VERSION
# ip-10-0-0-45.ap-south-1.compute.internal   Ready    <none>   5m    v1.30.x
# ip-10-0-1-23.ap-south-1.compute.internal   Ready    <none>   5m    v1.30.x
# two nodes in "Ready" = cluster is healthy

# ── STEP 4: Platform resources (~8 minutes) ───────────────────────────────────
cd terraform/platform

# Downloads providers (aws ~>6.0, helm ~>3.0) and connects to S3 backend
terraform init

# Creates: RDS PostgreSQL, Secrets Manager secrets,
#          ALB Ingress Controller (Helm), Metrics Server (Helm),
#          DynamoDB audit_events table, IRSA roles for audit + notification services
terraform apply

# ── STEP 5: Initialize the database (one-time, after RDS is created) ──────────
# RDS only creates the database — it does NOT create service-specific users
# patient_svc and appt_svc must be created manually via a psql pod inside the cluster
# See Doc 07 for the full DB user initialization procedure

# ── STEP 6: Create K8s Secrets from Secrets Manager ──────────────────────────
# Pull DATABASE_URL values from Secrets Manager and create K8s Secrets in the prod namespace
# See Doc 07 for the full secret creation commands

# ── STEP 7: Push images to ECR ────────────────────────────────────────────────
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1
SHA=$(git rev-parse --short HEAD)    # use git SHA as the image tag (immutable, traceable)

# Log in to ECR (token valid for 12 hours)
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Build, tag with git SHA, and push each service image
for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  ( cd services/$svc && docker build -t "$ECR:$SHA" . && docker push "$ECR:$SHA" )
done

# ── STEP 8: Deploy with Helm (prod values) ────────────────────────────────────
# Creates namespace prod if it doesn't exist; installs or upgrades each release
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.tag="$SHA" \
    --namespace prod --create-namespace
done

# Watch all pods start — should reach 2/2 Running for each service
kubectl get pods -n prod -w

# ── STEP 9: Apply Ingress ─────────────────────────────────────────────────────
# Creates the ALB with path-based routing to all 4 services
kubectl apply -f k8s/ingress.yaml

# Wait ~2 minutes for ALB provisioning, then get the DNS name
kubectl get ingress cloudcare-ingress -n prod

ALB=$(kubectl get ingress cloudcare-ingress -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Verify APIs are reachable
curl "http://$ALB/health"        # → {"status":"ok"}
curl "http://$ALB/patients"      # → [] (empty array on fresh DB)
```

---

## 6. Destroy at end of session — ALWAYS DO THIS

```bash
# Remove Helm releases first
# ALBs created by Ingress must be deleted BEFORE Terraform destroys the VPC
# otherwise the VPC destroy fails because the ALB still exists inside it
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod 2>/dev/null || true
done
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall metrics-server -n kube-system 2>/dev/null || true

# Destroy platform first (it depends on eks outputs)
cd terraform/platform
terraform destroy -auto-approve    # ~5 minutes — destroys RDS, DynamoDB, IAM roles, Secrets

# Then destroy eks
cd ../eks
terraform destroy -auto-approve    # ~10 minutes — destroys EKS, nodes, VPC, ECR

# DO NOT destroy bootstrap — it holds all your Terraform state
# bootstrap costs ~$0.01/month — always leave it running
```

---

## ✅ Checkpoint — done when:

- [ ] `terraform apply` in bootstrap creates S3 + DynamoDB with no errors
- [ ] `terraform apply` in eks takes 10–15 min and ends with no errors
- [ ] `kubectl get nodes` shows 2 nodes in `Ready` status with IPs from `10.0.0.x` or `10.0.1.x` (public subnets)
- [ ] `terraform apply` in platform creates RDS + Secrets Manager + ALB controller + DynamoDB
- [ ] `kubectl get pods -n prod` shows all 4 services running after Helm deploy
- [ ] `kubectl get ingress -n prod` shows an ALB hostname
- [ ] `curl http://<alb>/health` returns `{"status":"ok"}`
- [ ] `terraform destroy` in platform + eks cleans up cleanly
- [ ] You can explain: why are EKS nodes in public subnets in this setup?
- [ ] You can explain: why does `kubernetes.io/role/elb` tag exist on subnets?
- [ ] You can explain: why did the ALB controller need `vpcId` set explicitly?
- [ ] You can explain: what does the OIDC provider enable?

Next: **[06a — CI/CD Concepts](06a-cicd-concepts.md)** — understand how GitHub Actions
automates the build → push → deploy flow for each microservice independently.
