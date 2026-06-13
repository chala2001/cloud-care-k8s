# Use a t3.micro EC2 instance as NAT instead of NAT Gateway ($32/mo)
# Worker nodes in private subnets need outbound internet to pull images from ECR

# Amazon's old pre-built NAT AMI (amzn-ami-vpc-nat-*) is deprecated since AL1 EOL.
# We use Amazon Linux 2023 and configure NAT ourselves via user_data — two commands:
#   1. enable IP forwarding (kernel level)
#   2. enable masquerading (rewrite source IP to NAT instance's public IP)

data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]    # Amazon Linux 2023, x86_64
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
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
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id         # must be in a PUBLIC subnet
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  # source_dest_check = false is REQUIRED for NAT
  # normally EC2 drops packets that aren't addressed to it
  # NAT needs to forward packets destined for the internet → must disable this check

  user_data = <<-EOF
    #!/bin/bash
    # Enable IP forwarding — allows the kernel to route packets between interfaces
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

    # Enable masquerading — rewrites outbound packet source IP to this instance's
    # public IP, so reply packets know how to get back through the NAT
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    # Persist iptables rules across reboots
    dnf install -y iptables-services
    service iptables save
    systemctl enable iptables
  EOF

  tags = { Name = "cloudcare-k8s-nat" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"    # all outbound traffic from private subnets
  network_interface_id   = aws_instance.nat.primary_network_interface_id
  # → goes through the NAT instance → out to the internet
  # EKS nodes use this route to pull Docker images from ECR
}
