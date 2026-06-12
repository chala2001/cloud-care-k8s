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