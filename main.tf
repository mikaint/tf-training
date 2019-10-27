provider "aws" {
  region = var.aws_region
}

module "keypair" {
  source = "mitchellh/dynamic-keys/aws"
  path   = "${path.root}/keys"
  name   = "${var.key_name}"
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

data "aws_ami" "server_ami" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*-x86_64-gp2"]
  }
}


resource "aws_launch_configuration" "asg_conf" {
  name_prefix = "asg-"

  image_id             = "${data.aws_ami.server_ami.id}"
  instance_type        = "t2.micro"
  security_groups      = ["${aws_security_group.nodes_sg.id}"]
  key_name             = "${var.key_name}"

  user_data = "${local.user_data}"

  lifecycle {
    create_before_destroy = true
  }
}



resource "aws_autoscaling_group" "auto_scaling_group" {
  # Force a redeployment when launch configuration changes.
  # This will reset the desired capacity if it was changed due to
  # autoscaling events.
  name = "${aws_launch_configuration.asg_conf.name}"

  min_size             = 1
  desired_capacity     = 1
  max_size             = 3
  health_check_type    = "ELB"
  launch_configuration = "${aws_launch_configuration.asg_conf.name}"
  vpc_zone_identifier  = "${aws_subnet.private_subnets.*.id}"
  enabled_metrics      = ["GroupInServiceInstances"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${aws_launch_configuration.asg_conf.name}"
    propagate_at_launch = true
  }
}

locals {
  user_data = <<EOF
    #cloud-config
    runcmd:
    - yum install -y httpd && systemctl start httpd && systemctl enable httpd
    - amazon-linux-extras install php7.2
    - echo "<?php echo 'This is version 1<br>' .  @file_get_contents(\"http://instance-data/latest/meta-data/placement/availability-zone/\"); ?>" >  /var/www/html/index.php
    - service httpd restart
  EOF
}

resource "aws_autoscaling_attachment" "alb_autoscale" {
  alb_target_group_arn   = "${aws_lb_target_group.lb_target_group.arn}"
  autoscaling_group_name = "${aws_autoscaling_group.auto_scaling_group.id}"
}


resource "aws_security_group" "nodes_sg" {
  description = "Security group for ec2 instances"
  vpc_id      = "${aws_vpc.main.id}"
  name        = "nodes-sg"

  tags = {
    Name        = "nodes-sg"
  }
}

resource "aws_security_group_rule" "nodes-sg-inbound-http" {
  type              = "ingress"
  security_group_id = "${aws_security_group.nodes_sg.id}"
  from_port         = 80
  to_port           = 80
  protocol          = "TCP"

  source_security_group_id = "${aws_security_group.sg_load_balancer.id}"
}

resource "aws_security_group_rule" "nodes-sg-inbound-ssh" {
  type              = "ingress"
  security_group_id = "${aws_security_group.nodes_sg.id}"
  from_port         = 22
  to_port           = 22
  protocol          = "TCP"

  source_security_group_id = "${aws_security_group.bastion-sg.id}"
}

resource "aws_security_group_rule" "nodes-sg-outbound" {
  type              = "egress"
  security_group_id = "${aws_security_group.nodes_sg.id}"
  from_port         = -1
  to_port           = 0
  protocol          = "-1"

  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_autoscaling_policy" "asg_cpu_policy_scale_up" {
  name                   = "asg-cpu-policy-scale-up"
  scaling_adjustment     = 1
  autoscaling_group_name = "${aws_autoscaling_group.auto_scaling_group.name}"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "cpu_alarm_scale_up" {
  alarm_name          = "cpu-alarm-scale-up"
  alarm_description   = "CPU usage over 40%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "40"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.auto_scaling_group.name}"
  }

  actions_enabled = true
  alarm_actions   = ["${aws_autoscaling_policy.asg_cpu_policy_scale_up.arn}"]
}

resource "aws_autoscaling_policy" "asg_cpu_policy_scale_down" {
  name                   = "asg-cpu-policy-scale-down"
  scaling_adjustment     = "-1"
  autoscaling_group_name = "${aws_autoscaling_group.auto_scaling_group.name}"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "cpu_alarm_scale_down" {
  alarm_name          = "cpu-alarm-scale-down"
  alarm_description   = "CPU usage below 5%"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "5"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.auto_scaling_group.name}"
  }

  actions_enabled = true
  alarm_actions   = ["${aws_autoscaling_policy.asg_cpu_policy_scale_down.arn}"]
}



resource "aws_instance" "bastion-host" {
  count                       = "${length(aws_subnet.public_subnets)}"
  ami                         = "${data.aws_ami.server_ami.id}"
  instance_type               = "t2.micro"
  key_name                    = "${var.key_name}"
  subnet_id                   = "${aws_subnet.public_subnets.*.id[count.index]}"
  vpc_security_group_ids      = ["${aws_security_group.bastion-sg.id}"]
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "Bastion host ${count.index+1}"
  }
}

# remember to add ingress for nodes-sg
resource "aws_security_group" "bastion-sg" {
  name   = "bastion-security-group"
  vpc_id = "${aws_vpc.main.id}"

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = -1
    from_port   = 0 
    to_port     = 0 
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "eip-nats" {
  count = "${length(aws_subnet.public_subnets)}"
  vpc   = true

  tags = {
    Name = "eip-nat"
  }
}

resource "aws_nat_gateway" "nat-gws" {
  count         = "${length(aws_subnet.public_subnets)}"
  allocation_id = "${aws_eip.eip-nats.*.id[count.index]}"
  subnet_id     = "${aws_subnet.public_subnets.*.id[count.index]}"

  tags = {
    Name        = "nat-gw"
  }
}

resource "aws_route_table" "private-rt" {
  count  = "${length(aws_subnet.private_subnets)}"
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.nat-gws.*.id[count.index]}"
  }

  tags = {
    Name        = "private-route-table-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private-rt" {
  count          = "${length(aws_subnet.private_subnets)}"
  subnet_id      = "${aws_subnet.private_subnets.*.id[count.index]}"
  route_table_id = "${aws_route_table.private-rt.*.id[count.index]}"
}