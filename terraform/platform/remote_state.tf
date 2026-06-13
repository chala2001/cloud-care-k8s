# Read outputs from the eks stack — so we know the VPC, subnets, and cluster name
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "cloudcare-k8s-tfstate-670794226080"
    key    = "eks/terraform.tfstate"    # location of the eks stack's state file
    region = "ap-south-1"
  }
}

# Now use outputs like:
# data.terraform_remote_state.eks.outputs.vpc_id
# data.terraform_remote_state.eks.outputs.private_subnet_ids