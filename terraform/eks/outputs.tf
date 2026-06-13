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