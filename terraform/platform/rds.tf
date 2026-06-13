# ── Subnet Group: which subnets RDS can use ───────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "cloudcare-k8s-db"
  subnet_ids = data.terraform_remote_state.eks.outputs.db_subnet_ids
  # RDS lives in the dedicated database subnet layer (10.0.20.x, 10.0.21.x)
  # separate from EKS nodes — matches the 3-layer design from cloud-care v1
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