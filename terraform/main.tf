Configure the AWS Provider
provider "aws" {
region = "us-east-1"
}

--- Networking ---
Create a Virtual Private Cloud (VPC)
resource "aws_vpc" "my_app" {
cidr_block = "10.0.0.0/16"
tags = {
Name = "my-app-vpc"
}
}

Create two public subnets in different Availability Zones for high availability
resource "aws_subnet" "public_a" {
vpc_id                  = aws_vpc.my_app.id
cidr_block              = "10.0.1.0/24"
availability_zone       = "us-east-1a"
map_public_ip_on_launch = true # Instances in this subnet get a public IP
tags = {
Name = "my-app-public-a"
}
}

resource "aws_subnet" "public_b" {
vpc_id                  = aws_vpc.my_app.id
cidr_block              = "10.0.2.0/24"
availability_zone       = "us-east-1b"
map_public_ip_on_launch = true
tags = {
Name = "my-app-public-b"
}
}

Create an Internet Gateway to allow communication with the internet
resource "aws_internet_gateway" "my_app" {
vpc_id = aws_vpc.my_app.id
tags = {
Name = "my-app-igw"
}
}

Create a Route Table to route traffic from the subnets to the internet
resource "aws_route_table" "public" {
vpc_id = aws_vpc.my_app.id
route {
cidr_block = "0.0.0.0/0" # All traffic
gateway_id = aws_internet_gateway.my_app.id
}
tags = {
Name = "my-app-public-rt"
}
}

Associate the subnets with the route table
resource "aws_route_table_association" "public_a" {
subnet_id      = aws_subnet.public_a.id
route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
subnet_id      = aws_subnet.public_b.id
route_table_id = aws_route_table.public.id
}

--- Security ---
Create a Security Group (firewall) for the Application Load Balancer
resource "aws_security_group" "alb" {
name        = "my-app-alb-sg"
description = "Allow HTTP inbound traffic"
vpc_id      = aws_vpc.my_app.id

ingress {
from_port   = 80
to_port     = 80
protocol    = "tcp"
cidr_blocks = ["0.0.0.0/0"] # Allow from anywhere
}

egress {
from_port   = 0
to_port     = 0
protocol    = "-1"
cidr_blocks = ["0.0.0.0/0"]
}
}

Create a Security Group for the ECS Fargate service
resource "aws_security_group" "ecs_service" {
name        = "my-app-ecs-sg"
description = "Allow inbound traffic from the ALB"
vpc_id      = aws_vpc.my_app.id

ingress {
from_port       = 80
to_port         = 80
protocol        = "tcp"
security_groups = [aws_security_group.alb.id] # Only allow from the ALB
}

egress {
from_port   = 0
to_port     = 0
protocol    = "-1"
cidr_blocks = ["0.0.0.0/0"]
}
}

--- Application Load Balancer (ALB) ---
resource "aws_lb" "my_app" {
name               = "my-app-alb"
internal           = false
load_balancer_type = "application"
security_groups    = [aws_security_group.alb.id]
subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

resource "aws_lb_target_group" "my_app" {
name        = "my-app-tg"
port        = 80
protocol    = "HTTP"
vpc_id      = aws_vpc.my_app.id
target_type = "ip"
health_check {
path = "/"
}
}

resource "aws_lb_listener" "http" {
load_balancer_arn = aws_lb.my_app.arn
port              = "80"
protocol          = "HTTP"

default_action {
type             = "forward"
target_group_arn = aws_lb_target_group.my_app.arn
}
}

--- ECS Fargate ---
Create the ECS Cluster
resource "aws_ecs_cluster" "my_app" {
name = "my-app-cluster"
}

Create the IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
name = "ecs-task-execution-role"
assume_role_policy = jsonencode({
Version = "2012-10-17",
Statement = [
{
Action = "sts:AssumeRole",
Effect = "Allow",
Principal = {
Service = "https://www.google.com/search?q=ecs-tasks.amazonaws.com"
}
}
]
})
}

Attach the standard AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
role       = aws_iam_role.ecs_task_execution_role.name
policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

Create the Task Definition (blueprint for our container)
resource "aws_ecs_task_definition" "my_app" {
family                   = "my-app-task"
network_mode             = "awsvpc"
requires_compatibilities = ["FARGATE"]
cpu                      = "256"  # 0.25 vCPU
memory                   = "512"  # 0.5 GB
execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

For the initial apply, we use the account ID and a 'latest' tag.
Replace '123456789012' with your actual 12-digit AWS Account ID.
container_definitions = jsonencode([
{
name      = "my-app-container",
image     = "https://www.google.com/search?q=123456789012.dkr.ecr.us-east-1.amazonaws.com/my-aws-app:latest",
essential = true,
portMappings = [
{
containerPort = 80,
hostPort      = 80
}
],
logConfiguration = {
logDriver = "awslogs",
options = {
"awslogs-group"         = "/ecs/my-app-task",
"awslogs-region"        = "us-east-1",
"awslogs-stream-prefix" = "ecs"
}
}
}
])
}

Create the ECS Service to run the task
resource "aws_ecs_service" "my_app" {
name            = "my-app-service"
cluster         = aws_ecs_cluster.my_app.id
task_definition = aws_ecs_task_definition.my_app.arn
desired_count   = 1
launch_type     = "FARGATE"

network_configuration {
subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
security_groups = [aws_security_group.ecs_service.id]
assign_public_ip = true
}

load_balancer {
target_group_arn = aws_lb_target_group.my_app.arn
container_name   = "my-app-container"
container_port   = 80
}

This ensures the service waits for the ALB to be ready
depends_on = [aws_lb_listener.http]
}

Create the CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs_logs" {
name = "/ecs/my-app-task"

tags = {
Application = "my-app"
Environment = "production"
}
}

--- Outputs ---
Output the DNS name of the ALB to access the application
output "app_url" {
value = aws_lb.my_app.dns_name
}