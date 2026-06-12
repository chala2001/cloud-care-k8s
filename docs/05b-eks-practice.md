# 05b — EKS Practice: Every Terraform File, Every Line

> **Read 05a first.** This doc writes every Terraform file for all 3 stacks
> with every line explained, then applies them in the correct order.
>
> ⚠️ **Cost reminder:** EKS = ~$0.10/hr. Destroy at the end of every session.

---

## 1. Create the directory structure

```bash
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
export AWS_PROFILE=cloudcare-k8s    # your AWS CLI profile
export AWS_REGION=ap-south-1

cd terraform/bootstrap
terraform init    # downloads the AWS provider plugin

# Get your AWS account ID automatically and use it in the bucket name
# This guarantees the bucket name is unique (your account ID is unique)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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

# ── Private Subnets (2 — one per AZ) ─────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  # count.index + 10 avoids overlap with public subnets
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
  # associate both public subnets with the public route table
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # private route table starts with no routes
  # the NAT route is added in nat.tf after the NAT instance is created
  tags = { Name = "cloudcare-k8s-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```

### terraform/eks/nat.tf

```hcl
# Use a t3.micro EC2 instance as NAT instead of NAT Gateway ($32/mo)
# Worker nodes in private subnets need outbound internet to pull images from ECR

data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]    # only AMIs published by Amazon
  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-*"]    # Amazon's pre-configured NAT AMI
    # this AMI has IP forwarding and masquerading (NAT) already configured
  }
}

resource "aws_security_group" "nat" {
  name   = "cloudcare-k8s-nat"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"               # -1 = all protocols
    cidr_blocks = ["10.0.0.0/16"]   # accept traffic from anywhere inside the VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]    # allow all outbound (needs to forward traffic to internet)
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat.id
  instance_type          = "t3.micro"                      # free tier eligible
  subnet_id              = aws_subnet.public[0].id         # must be in a PUBLIC subnet
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  # source_dest_check = false is REQUIRED for NAT
  # normally EC2 drops packets that aren't addressed to it
  # NAT needs to forward packets destined for the internet → must disable this check

  tags = { Name = "cloudcare-k8s-nat" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"    # all outbound traffic from private subnets
  network_interface_id   = aws_instance.nat.primary_network_interface_id
  # → goes through the NAT instance → out to the internet
  # EKS nodes use this to pull Docker images from ECR
}
```

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
    endpoint_private_access = true    # kubectl works from inside the VPC (e.g. from a bastion)
    endpoint_public_access  = false   # the K8s API server is NOT reachable from the internet
    # security best practice: only access kubectl from inside your VPC or via VPN
    security_group_ids = [aws_security_group.eks_cluster.id]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
  # Terraform must attach the IAM policy BEFORE creating the cluster
  # depends_on makes this ordering explicit
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
  # this is how pods get their images without any manual docker login
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
  subnet_ids      = aws_subnet.private[*].id    # nodes in PRIVATE subnets (no public IP)
  instance_types  = ["t3.micro"]               # free tier eligible

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
  # needed for the thumbprint below
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]    # AWS STS is the audience
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  # the thumbprint is the certificate fingerprint — proves this OIDC endpoint is legitimate
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
          # replace "your-github-username" with your actual GitHub username
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
  # each.key = "patient-service", "appointment-service", etc.

  name                 = "cloudcare-k8s-${each.key}"
  # creates: cloudcare-k8s-patient-service, cloudcare-k8s-appointment-service, etc.
  image_tag_mutability = "MUTABLE"
  # MUTABLE = the same tag (e.g. "latest") can point to different images
  # IMMUTABLE = once pushed, a tag cannot be overwritten (stricter, safer for prod)

  image_scanning_configuration {
    scan_on_push = true    # automatically scan every pushed image for CVE vulnerabilities
    # free — results visible in AWS ECR console under "Image scan findings"
  }
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
  # outputs a map: { "patient-service" => "123456.dkr.ecr.ap-south-1.amazonaws.com/..." }
  # platform stack and CI pipeline read this to know where to push images
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

# Now use outputs like:
# data.terraform_remote_state.eks.outputs.vpc_id
# data.terraform_remote_state.eks.outputs.private_subnet_ids
```

### terraform/platform/rds.tf

```hcl
# ── Subnet Group: which subnets RDS can use ───────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "cloudcare-k8s-db"
  subnet_ids = data.terraform_remote_state.eks.outputs.private_subnet_ids
  # RDS lives in private subnets — no public access
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
    # no public internet access to the database
  }
}

# ── Random password for master DB user ───────────────────────────────────────
resource "random_password" "db_master" {
  length  = 24
  special = false    # no special chars — some DB drivers don't handle them well
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "cloudcare-k8s-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"    # free tier: 750 hrs/month for 12 months
  allocated_storage = 20               # 20 GB — minimum, free tier includes up to 20 GB

  db_name  = "cloudcare"              # the database to create on first launch
  username = "admin"                  # master user (we create schema-specific users via init.sql)
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false    # single-AZ — multi-AZ doubles the cost
  publicly_accessible    = false    # private only — no direct internet access

  skip_final_snapshot = true        # allow terraform destroy without creating a snapshot
  # REMOVE this in a real production database — you want a final snapshot for recovery
}
```

### terraform/platform/secrets.tf

```hcl
# ── Random passwords for service-specific DB users ────────────────────────────
resource "random_password" "patient_db"      { length = 24; special = false }
resource "random_password" "appointment_db"  { length = 24; special = false }

# ── Secrets Manager secrets — one per service ─────────────────────────────────
# The External Secrets Operator (ESO) will sync these into Kubernetes Secrets (Doc 07)

resource "aws_secretsmanager_secret" "patient_db" {
  name = "cloudcare-k8s/patient-service/db"
  # path format: project/service/type — easy to manage with IAM path-based policies
}

resource "aws_secretsmanager_secret_version" "patient_db" {
  secret_id = aws_secretsmanager_secret.patient_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://patient_svc:${random_password.patient_db.result}@${aws_db_instance.main.endpoint}/cloudcare"
    # patient_svc is the schema-specific postgres user (created by init.sql equivalent)
    # aws_db_instance.main.endpoint = the RDS hostname (set by AWS after creation)
  })
}

resource "aws_secretsmanager_secret" "appointment_db" {
  name = "cloudcare-k8s/appointment-service/db"
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
          # only the alb controller ServiceAccount in kube-system can assume this role
        }
      }
    }]
  })
}

# AWS provides the policy for the ALB controller — download it:
# curl -o alb-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_role_policy" "alb_controller" {
  name   = "cloudcare-k8s-alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/alb-policy.json")    # load from local file
}

# Install the ALB Ingress Controller via Helm (managed by Terraform)
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  set { name = "clusterName"; value = data.terraform_remote_state.eks.outputs.cluster_name }
  set { name = "serviceAccount.create"; value = "true" }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
    # this annotation on the ServiceAccount enables IRSA for the controller pod
  }
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
# ── STEP 1: Bootstrap (one-time, already done) ────────────────────────────────
cd terraform/bootstrap
terraform init && terraform apply -var="state_bucket_name=cloudcare-k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"

# ── STEP 2: EKS cluster (takes 10–15 minutes) ─────────────────────────────────
cd terraform/eks
terraform init    # downloads providers, configures S3 backend
terraform plan    # preview what will be created
terraform apply   # creates VPC, subnets, NAT, EKS cluster, node group, OIDC, ECR
# ⚠️ billing starts here

# ── STEP 3: Connect kubectl to the new cluster ────────────────────────────────
aws eks update-kubeconfig --name cloudcare-k8s --region ap-south-1
# this writes credentials to ~/.kube/config

kubectl get nodes
# NAME                                        STATUS   ROLES    AGE   VERSION
# ip-10-0-10-45.ap-south-1.compute.internal  Ready    <none>   5m    v1.30.x
# ip-10-0-11-23.ap-south-1.compute.internal  Ready    <none>   5m    v1.30.x
# two nodes in "Ready" = cluster is healthy

# ── STEP 4: Platform resources ────────────────────────────────────────────────
cd terraform/platform
terraform init
terraform apply   # creates RDS, Secrets Manager, ALB controller, Metrics Server

# ── STEP 5: Push images to ECR ────────────────────────────────────────────────
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

for svc in patient-service appointment-service audit-service notification-service; do
  ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc"
  cd services/$svc
  docker build -t "$ECR:latest" .
  docker push "$ECR:latest"
  cd ../..
done

# ── STEP 6: Deploy with Helm (prod values) ────────────────────────────────────
for svc in patient-service appointment-service audit-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    -f helm/$svc/values-prod.yaml \
    --set image.repository="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/cloudcare-k8s-$svc" \
    --set image.tag=latest \
    --namespace prod --create-namespace
done

kubectl get pods -n prod
# all should show 1/1 or 2/2 Running
```

---

## 6. Destroy at end of session — ALWAYS DO THIS

```bash
# Remove Helm releases first
# (K8s resources like ALBs must be cleaned up before Terraform destroys the VPC)
for svc in patient-service appointment-service audit-service notification-service; do
  helm uninstall $svc -n prod 2>/dev/null || true
done

# Destroy platform first (it depends on eks)
cd terraform/platform
terraform destroy -auto-approve    # takes ~5 minutes

# Then destroy eks
cd terraform/eks
terraform destroy -auto-approve    # takes ~10 minutes

# DO NOT destroy bootstrap — it holds all your Terraform state
# bootstrap costs ~$0.01/month — always leave it running
```

---

## ✅ Checkpoint — done when:

- [ ] `terraform apply` in bootstrap creates S3 + DynamoDB with no errors
- [ ] `terraform apply` in eks takes 10–15 min and ends with no errors
- [ ] `kubectl get nodes` shows 2 nodes in `Ready` status
- [ ] `terraform apply` in platform creates RDS + Secrets Manager + ALB controller
- [ ] `kubectl get pods -n prod` shows all 4 services running
- [ ] `terraform destroy` in platform + eks cleans up cleanly
- [ ] You can explain: why does `kubernetes.io/role/elb` tag exist on subnets?
- [ ] You can explain: why is `source_dest_check = false` needed on the NAT instance?
- [ ] You can explain: what does the OIDC provider enable?

Next: **[06a — CI/CD Concepts](06a-cicd-concepts.md)** — understand how GitHub Actions
automates the build → push → deploy flow for each microservice independently.
