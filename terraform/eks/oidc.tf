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
          "token.actions.githubusercontent.com:sub" = "repo:your-github-chala2001/cloud-care-k8s:*"
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
resource "aws_iam_role_policy" "github_terraform" {
  name = "cloudcare-k8s-github-terraform-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:*", "eks:*", "ecr:*", "iam:*",
                    "rds:*", "secretsmanager:*", "s3:*",
                    "dynamodb:*", "elasticloadbalancing:*"]
        Resource = "*"
        # broad permissions for Terraform to manage all infrastructure
        # in a real project you'd scope these more tightly
        # for a learning project this is acceptable
      }
    ]
  })
}