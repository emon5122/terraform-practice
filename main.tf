terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4"
    }
    ansible = {
      version = "~> 1.3.0"
      source  = "ansible/ansible"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}
provider "ansible" {}
provider "cloudflare" {}

variable "zone_id" {
  default = "e1643b677698135cffb16b4a3267b076"
}
variable "ec2_instance_count" {
  default = 1
}

resource "aws_vpc" "web_vpc" {
  assign_generated_ipv6_cidr_block = true
  cidr_block                       = "10.0.0.0/16"
}

resource "aws_subnet" "web_subnet" {
  assign_ipv6_address_on_creation = true
  availability_zone               = "ap-southeast-1a"
  cidr_block                      = "10.0.0.0/24"
  vpc_id                          = aws_vpc.web_vpc.id
  map_public_ip_on_launch         = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.web_vpc.ipv6_cidr_block, 8, 1)
}

resource "aws_internet_gateway" "web_igw" {
  vpc_id = aws_vpc.web_vpc.id
}

resource "aws_route_table" "web_rt" {
  vpc_id = aws_vpc.web_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.web_igw.id
  }
}

resource "aws_route_table_association" "web_assoc" {
  subnet_id      = aws_subnet.web_subnet.id
  route_table_id = aws_route_table.web_rt.id
}

resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Allow SSH, HTTP, HTTPS inbound traffic"
  vpc_id      = aws_vpc.web_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 5901
    to_port     = 5901
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "web_eip" {
  count    = var.ec2_instance_count
  domain   = "vpc"
  instance = aws_instance.web[count.index].id
}

resource "aws_instance" "web" {
  count                       = var.ec2_instance_count
  ami                         = "ami-01938df366ac2d954"
  instance_type               = "t2.micro"
  key_name                    = "chilekotha"
  subnet_id                   = aws_subnet.web_subnet.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  ipv6_address_count          = 1
  enable_primary_ipv6         = true
  private_ip                  = "10.0.0.${count.index + 10}"

  provisioner "local-exec" {
    command = "echo 'Wait Until SSH is ready'"
  }
  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ubuntu"
    private_key = file("/Users/emon/Downloads/chilekotha.pem")
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp2"
  }

  tags = {
    Name = "Test-${count.index}"
  }

  depends_on = [aws_vpc.web_vpc]
}

resource "cloudflare_record" "www" {
  for_each = { for i, instance in aws_instance.web : "web-${i}" => instance }

  zone_id    = var.zone_id
  name       = each.value.tags.Name
  content    = each.value.public_ip
  type       = "A"
  proxied    = true
  depends_on = [aws_instance.web]
}

resource "cloudflare_record" "www6" {
  for_each = { for i, instance in aws_instance.web : "web6-${i}" => instance }

  zone_id    = var.zone_id
  name       = each.value.tags.Name
  content    = each.value.ipv6_addresses[0]
  type       = "AAAA"
  proxied    = true
  depends_on = [aws_instance.web]
}
resource "ansible_group" "web_servers" {
  name = "vnc_servers"
}

resource "ansible_host" "web" {
  count  = var.ec2_instance_count
  name   = aws_instance.web[count.index].public_ip
  groups = [ansible_group.web_servers.name]

  variables = {
    ansible_user                 = "ubuntu"
    ansible_ssh_private_key_file = "/Users/emon/Downloads/chilekotha.pem"
  }
  depends_on = [aws_instance.web]
}
resource "ansible_playbook" "vnc_setup" {
  count      = var.ec2_instance_count
  name       = ansible_host.web[count.index].name
  check_mode = false
  playbook   = "./playbook/vnc-setup.yml"
  depends_on = [ansible_host.web]
}
