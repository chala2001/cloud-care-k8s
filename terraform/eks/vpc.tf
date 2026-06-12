# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"    # 65,536 IP addresses — more than enough
  enable_dns_hostnames = true              # required for EKS: nodes need DNS hostnames
  enable_dns_support   = true             # required for EKS: internal DNS resolution

  tags = {
    Name = "cloudcare-k8s-vpc"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
    # this tag tells the ALB Ingress Controller this VPC belongs to our cluster
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id    # attach to our VPC
  # the IGW is the door between the VPC and the public internet
  # public subnets route outbound traffic through this
  tags = { Name = "cloudcare-k8s-igw" }
}

# ── Public Subnets (2 — one per AZ) ──────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = 2    # create 2 copies of this resource (one per AZ)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  # cidrsubnet carves out smaller subnets from the VPC CIDR
  # count.index = 0 → 10.0.0.0/24
  # count.index = 1 → 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # count.index = 0 → ap-south-1a
  # count.index = 1 → ap-south-1b
  map_public_ip_on_launch = true    # EC2 instances in this subnet get a public IP automatically

  tags = {
    Name = "cloudcare-k8s-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
    # tells ALB Ingress Controller: "create internet-facing ALBs in these subnets"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# ── Private Subnets / App Layer (2 — one per AZ) ─────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  # count.index = 0 → 10.0.10.0/24
  # count.index = 1 → 10.0.11.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "cloudcare-k8s-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
    # tells ALB Ingress Controller: "create internal ALBs in these subnets"
    "kubernetes.io/cluster/cloudcare-k8s" = "shared"
  }
}

# ── Database Subnets (2 — one per AZ) ────────────────────────────────────────
resource "aws_subnet" "database" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 20)
  # count.index = 0 → 10.0.20.0/24
  # count.index = 1 → 10.0.21.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # separate layer: only RDS lives here — EKS nodes cannot reach it without SG rules
  # mirrors the 3-layer pattern from cloud-care v1

  tags = {
    Name = "cloudcare-k8s-db-${count.index}"
  }
}

# ── Route Tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"             # all outbound traffic
    gateway_id = aws_internet_gateway.main.id    # goes through the Internet Gateway
  }
  tags = { Name = "cloudcare-k8s-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # NAT route is added in nat.tf after the NAT instance is created
  tags = { Name = "cloudcare-k8s-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB subnets use the same private route table — no internet access needed
resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.private.id
}