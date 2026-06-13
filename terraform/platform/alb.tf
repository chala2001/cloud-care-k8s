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