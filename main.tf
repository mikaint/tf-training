provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket = "mystate123"
    key    = "terraform.tfstate"
    region = "eu-west-1"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "main-igw"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "private_subnets" {
  count                   = 3
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "${data.aws_availability_zones.available.names[count.index]}"
  cidr_block              = "10.0.${count.index + 1}.0/24"

  tags = {
    Name = "private-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "public_subnets" {
  count                   = 3
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "${data.aws_availability_zones.available.names[count.index]}"
  cidr_block              = "10.0.10${count.index + 1}.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public-rt" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.main.id}"
  }

  tags = {
    Name = "public-subnet-route-table"
  }
}

resource "aws_route_table_association" "public-rt" {
  count          = "${length(aws_subnet.public_subnets)}"
  subnet_id      = "${aws_subnet.public_subnets.*.id[count.index]}"
  route_table_id = "${aws_route_table.public-rt.id}"
}

resource "aws_lb" "load_balancer" {
  name               = "test-load-balancer"
  security_groups    = ["${aws_security_group.sg_load_balancer.id}"]
  subnets            = "${aws_subnet.public_subnets.*.id}"
  internal           = false
  load_balancer_type = "application"
  enable_deletion_protection = false

  tags = {
    Name        = "test-load-balancer"
  }
}

resource "aws_lb_target_group" "lb_target_group" {
  name     = "lb-target-group"
  port     = "80"
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.main.id}"
  target_type = "instance"

  health_check {
    path                = "/"
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    port                = 80
  }

  tags = {
    Name        = "alb-target-group"
  }
}

resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = "${aws_lb.load_balancer.arn}"
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_lb_target_group.lb_target_group.arn}"
    type             = "forward"
  }
}

resource "aws_security_group" "sg_load_balancer" {
  name        = "load-balancer-security-group"
  description = "Load balancer security group"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = "${var.whitelisted_ips}"
  }

  # Allow all outbound traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "lb-security-group"
  }
}