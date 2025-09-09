# --- Provider & Region Configuration ---
# This tells Terraform we are working with the AWS provider and in which region.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- New IAM Role for ECS ---
# This is the "permission slip" our container service needs.

# 1. Define the IAM Role that ECS can assume
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  # This "assume role policy" specifies which AWS service is allowed to use this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# 2. Attach the standard AWS-managed policy to the role.
# This policy grants all the necessary permissions for Fargate to pull ECR images and write logs.
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


# --- Networking (VPC, Subnets, etc.) ---
# We define a private network for our application to live in.

# 1. Create a Virtual Private Cloud (VPC)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "my-app-vpc"
  }
}

# 2. Create two public subnets in different Availability Zones for high availability
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true # Instances in this subnet get a public IP
  tags = {
    Name = "public-subnet-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-b"
  }
}

# 3. Create an Internet Gateway to allow traffic to/from the internet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "my-app-igw"
  }
}

# 4. Create a Route Table to route internet-bound traffic to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0" # Represents all internet traffic
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "public-route-table"
  }
}

# 5. Associate our subnets with the route table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Security (Firewall Rules) ---

# 1. Create a Security Group for the Application Load Balancer (ALB)
# This allows public web traffic (HTTP) into our VPC.
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

# 2. Create a Security Group for our Fargate service
# This allows traffic only from our ALB, not directly from the internet.
resource "aws_security_group" "fargate_sg" {
  name        = "fargate-sg"
  description = "Allow traffic from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Only allows traffic from the ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# --- Container Orchestration (ECS Fargate) ---

# 1. Create an ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "my-app-cluster"
}

# 2. Define the Task Definition
# This is a blueprint for our container, specifying the image, CPU, memory, and port.
resource "aws_ecs_task_definition" "my_app" {
  family                   = "my-app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"  # 0.25 vCPU
  memory                   = "512"  # 512 MB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "my-app-container"
      # IMPORTANT: Replace 123456789012 with your actual 12-digit AWS Account ID
      image     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-aws-app:latest"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
    }
  ])
}

# 3. Create the ECS Service
# This runs and maintains our task definition, ensuring it's always running.
resource "aws_ecs_service" "main" {
  name            = "my-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.my_app.arn
  desired_count   = 1 # Run one instance of our container
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups = [aws_security_group.fargate_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "my-app-container"
    container_port   = 80
  }

  # This ensures the load balancer is ready before the service starts
  depends_on = [aws_lb_listener.http]
}


# --- Load Balancer ---

# 1. Create an Application Load Balancer (ALB)
resource "aws_lb" "main" {
  name               = "my-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# 2. Create a Target Group
# The ALB forwards requests to this group, which contains our container.
resource "aws_lb_target_group" "main" {
  name        = "my-app-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
}

# 3. Create a Listener
# This tells the ALB to listen for incoming HTTP traffic on port 80.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# --- Outputs ---
# This will print the public DNS name of our load balancer after it's created.
output "load_balancer_dns" {
  value = aws_lb.main.dns_name
}

