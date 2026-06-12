# Use a t3.micro EC2 instance as NAT instead of NAT Gateway ($32/mo)
# Worker nodes in private subnets need outbound internet to pull images from ECR

data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]    # only AMIs published by Amazon
  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-*"]    # Amazon's pre-configured NAT AMI
    # this AMI has IP forwarding and masquerading (NAT) already configured
  }
}

resource "aws_security_group" "nat" {
  name   = "cloudcare-k8s-nat"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"               # -1 = all protocols
    cidr_blocks = ["10.0.0.0/16"]   # accept traffic from anywhere inside the VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]    # allow all outbound (needs to forward traffic to internet)
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat.id
  instance_type          = "t3.micro"                      # free tier eligible
  subnet_id              = aws_subnet.public[0].id         # must be in a PUBLIC subnet
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  # source_dest_check = false is REQUIRED for NAT
  # normally EC2 drops packets that aren't addressed to it
  # NAT needs to forward packets destined for the internet → must disable this check

  tags = { Name = "cloudcare-k8s-nat" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"    # all outbound traffic from private subnets
  network_interface_id   = aws_instance.nat.primary_network_interface_id
  # → goes through the NAT instance → out to the internet
  # EKS nodes use this to pull Docker images from ECR
}