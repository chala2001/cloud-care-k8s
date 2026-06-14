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
          "${data.terraform_remote_state.eks.outputs.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

# Fetch the ALB controller IAM policy from GitHub at plan time — no local file needed
data "http" "alb_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "cloudcare-k8s-alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = data.http.alb_policy.response_body
}

# Install the ALB Ingress Controller via Helm (managed by Terraform)
# helm provider v3 uses set = [...] list syntax instead of set {} blocks
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version          = "1.7.1"
  wait             = false
  cleanup_on_fail  = true
  force_update     = true

  set = [
    {
      name  = "clusterName"
      value = data.terraform_remote_state.eks.outputs.cluster_name
    },
    {
      name  = "vpcId"
      value = data.terraform_remote_state.eks.outputs.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.alb_controller.arn
    }
  ]
}

# Install Metrics Server (required for HPA to read CPU metrics)
resource "helm_release" "metrics_server" {
  name            = "metrics-server"
  repository      = "https://kubernetes-sigs.github.io/metrics-server/"
  chart           = "metrics-server"
  namespace       = "kube-system"
  wait            = false
  cleanup_on_fail = true
  force_update    = true
}
