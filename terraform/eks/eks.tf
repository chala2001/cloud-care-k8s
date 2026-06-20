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
    endpoint_public_access  = true    # nodes and kubectl can reach the API over the internet
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
  subnet_ids      = aws_subnet.public[*].id     # nodes in PUBLIC subnets — direct internet access, no NAT dependency
  instance_types  = ["t3.small"]               # minimum viable for EKS (micro has too little RAM)

  scaling_config {
    desired_size = 3    # start with 3 nodes
    min_size     = 3    # never go below 3 (HA: tolerate one node failure)
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