provider "aws" {
  region = "ca-central-1"
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Create an internet gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Create a public subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ca-central-1a"
  map_public_ip_on_launch = true
}

# Create a route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Associate route table with the subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Create a security group for the EC2 instances
resource "aws_security_group" "instance" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
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
}

# Create IAM role for EC2 instances to pull from ECR
resource "aws_iam_role" "ec2_role" {
  name = "ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_policy_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  role = aws_iam_role.ec2_role.name
}

# Launch two EC2 instances running the Docker container
resource "aws_instance" "web" {
  count         = 2
  ami           = "ami-049332278e728bdb7" 
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public.id
  security_groups = [aws_security_group.instance.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install  docker -y
    service docker start
    usermod -a -G docker ec2-user
    aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 433596888974.dkr.ecr.ca-central-1.amazonaws.com/ppsre-app-ecr-repo
    docker pull 433596888974.dkr.ecr.ca-central-1.amazonaws.com/ppsre-app-ecr-repo:latest
    docker run -d -p 80:80 433596888974.dkr.ecr.ca-central-1.amazonaws.com/ppsre-app-ecr-repo:latest
  EOF

  tags = {
    Name = "web-server-${count.index}"
  }
}

resource "aws_instance" "nginx_lb" {
  ami           = "ami-049332278e728bdb7" # Replace with the latest Amazon Linux 2 AMI in ca-central-1
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public.id
  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install nginx -y
    systemctl start nginx
    systemctl enable nginx

    # Create NGINX configuration file
    cat <<EOT > /etc/nginx/conf.d/load_balancer.conf
    upstream backend {
        server ${aws_instance.web[0].private_ip}:80;
        server ${aws_instance.web[1].private_ip}:80;
    }
    server {
        listen 80;

        location / {
            proxy_pass http://backend;
            proxy_set_header Host $$host;
            proxy_set_header X-Real-IP $$remote_addr;
            proxy_set_header X-Forwarded-For $$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $$scheme;
        }
    }


    EOT

    # Restart NGINX to apply changes
    systemctl restart nginx
  EOF

  tags = {
    Name = "nginx-load-balancer"
  }
}


# Output the public IP of the NGINX load balancer
output "nginx_lb_public_ip" {
  value = aws_instance.nginx_lb.public_ip
}

# Output the public IPs of the web servers
output "web_server_public_ips" {
  value = [for instance in aws_instance.web : instance.public_ip]
}
