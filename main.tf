provider "aws" {
  #access_key = var.Access_ID
  #secret_key = var.Secret_Key
  region = "us-east-1"
}

# 1. Create VPC

resource "aws_vpc" "webapp_VPC" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "webapp_VPC"
  }
}

# 2. Create public & Private subnet.

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.webapp_VPC.id
  cidr_block = "10.0.1.0/24"

  tags = {
    Name = "public"
  }
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.webapp_VPC.id
  cidr_block = "10.0.2.0/24"

  tags = {
    Name = "private"
  }
}


# 3. create Internet Gateway.

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.webapp_VPC.id

  tags = {
    Name = "internet gateway"
  }
}

# 4. Create Elastic IP

resource "aws_eip" "lb" {
  vpc      = true
}

# 5. Nat Gateway.

resource "aws_nat_gateway" "gw" {
  allocation_id = aws_eip.lb.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "NAT GW"
  }
}

# 6. Create custom Route Table

resource "aws_route_table" "PublicRouteTable" {
  vpc_id = aws_vpc.webapp_VPC.id

  route {
    cidr_block = "10.0.1.0/24"
    gateway_id = aws_internet_gateway.gw.id
  }
 
  route {
    ipv6_cidr_block        = "::/0"
    egress_only_gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

resource "aws_route_table" "PrivateRouteTable" {
  vpc_id = aws_vpc.webapp_VPC.id

  route {
    cidr_block = "10.0.2.0/24"
    gateway_id = aws_nat_gateway.gw.id
  }
 
  route {
    ipv6_cidr_block        = "::/0"
    egress_only_gateway_id = aws_nat_gateway.gw.id
  }

  tags = {
    Name = "Private Route Table"
  }
}

# 7. Associate Security Group to allow port 22,80,443 from User to ALB.

resource "aws_security_group" "allow_Webtraffic" {
  name        = "allow_Webtraffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.webapp_VPC.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_Webtraffic"
  }
}

# 8. Associate Security Group to allow port 22,80,443 from ALB to ASG.

resource "aws_security_group" "allow_LBtraffic" {
  name        = "allow_Webtraffic"
  description = "Allow Load balancer traffic traffic"
  vpc_id      = aws_vpc.webapp_VPC.id

  
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = aws_security_group.allow_Webtraffic.id

  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_LBtraffic"
  }
}

# 9. Create Instance

resource "aws_instance" "webservers" {
	count = "${length(var.subnets_cidr)}" 
	ami = "${var.webservers_ami}"
	instance_type = "${var.instance_type}"
	security_groups = ["{aws_security_group.allow_LBtraffic.id}"]
	subnet_id = "${element(aws_subnet.private.*.id,count.index)}"
	user_data = "${file("install_httpd.sh")}"

resource "aws_volume_attachment" "ebs" {
  device_name = "/dev/sda"
  volume_id = aws_ebs_volume.example.id
  instance_id = aws_instance.web.id
 }

resource "aws_instance" "web" {
   ami = "${var.webservers_ami}"
   availability_zone = "${var.azs}"
   instance_type = "t3.micro"
 }

resource "aws_ebs_volume" "example" {
  availability_zone = "us-west-2a"
  size              = 1
}

	tags {
	  Name = "Server-${counter.index}"
	}
}

# 10. Create Application Load balancer.

resource "aws_lb" "ALB" {
  name               = "Alb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.allow_LBtraffic_sg.id}"]
  subnets            = ["${aws_subnet.public.*.id}"]

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/index.html"
    interval            = 30
  }

  instances                   = ["${aws_instance.webservers.*.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 100
  connection_draining         = true
  connection_draining_timeout = 300

  tags {
    Name = "Alb"
  }
}

# 11. Create Auto Scaling Group.

resource "aws_launch_configuration" "lconf" {
  image_id      = "${lookup(var.webserver_ami,var.region)}"
  instance_type = "t3.micro"
  security_groups        = ["${aws_security_group.private.id}"]
  key_name               = "${var.key_name}"
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install httpd -y
              service httpd start
              chkconfig httpd on
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "ASG" {
  launch_configuration = "${aws_launch_configuration.lconf.id}"
  availability_zones = ["${data.aws_availability_zones.azs.names}"]
  min_size = 2
  max_size = 10
  load_balancers = ["${aws_elb.ALB.name}"]
  health_check_type = "ALB"
  tag {
    key = "Name"
    value = "terraform-asg"
    propagate_at_launch = true
  }
}
