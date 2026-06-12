terraform {
  backend "s3" {
    bucket         = "cloudcare-k8s-tfstate-<your-account-id>"  # replace with your bucket name
    key            = "eks/terraform.tfstate"    # path inside the bucket for THIS stack's state
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-k8s-tfstate-670794226080"
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