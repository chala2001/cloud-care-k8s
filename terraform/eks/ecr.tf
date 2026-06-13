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