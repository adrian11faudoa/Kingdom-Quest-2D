# =============================================================================
# Module: ECS Fargate
# Runs the Kingdom Quest 2D game API as Docker containers on Fargate.
# Includes: ECR repo, ECS cluster, task definition, service, ALB, autoscaling.
#
# The API handles: player auth relay, leaderboards, cloud saves, analytics,
# multiplayer lobby signalling, and game event webhooks.
# =============================================================================

# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "api" {
  name                 = "${var.name_prefix}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true  # Automatically scan images for CVEs on push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.name_prefix}-ecr-api" }
}

# Lifecycle: keep last 20 images per tag prefix
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"  # Enables CloudWatch Container Insights for metrics
  }

  tags = { Name = "${var.name_prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1             # At least 1 task on regular Fargate
    weight            = 2
    capacity_provider = "FARGATE"
  }
  default_capacity_provider_strategy {
    weight            = 8             # Prefer Fargate Spot (up to 70% cheaper)
    capacity_provider = "FARGATE_SPOT"
  }
}

# ── CloudWatch Log Group ───────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}/api"
  retention_in_days = 30
}

# ── IAM Roles ─────────────────────────────────────────────────────────────────

# Task Execution Role — ECS agent uses this to pull images and push logs
resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow task execution role to read secrets from Secrets Manager
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${var.name_prefix}-ecs-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

# Task Role — the application container uses this for AWS API calls
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "task_permissions" {
  name = "${var.name_prefix}-ecs-task-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read/write player saves in S3
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-player-saves-${var.account_id}",
          "arn:aws:s3:::${var.name_prefix}-player-saves-${var.account_id}/*",
          "arn:aws:s3:::${var.name_prefix}-game-assets-${var.account_id}/*"
        ]
      },
      {
        # CloudWatch metrics for custom game metrics
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        # X-Ray tracing
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# ── Task Definition ───────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.api_image
      essential = true

      portMappings = [{
        containerPort = 8080
        protocol      = "tcp"
        name          = "api-http"
      }]

      environment = [
        { name = "NODE_ENV",             value = var.environment },
        { name = "PORT",                 value = "8080" },
        { name = "DB_HOST",              value = var.db_host },
        { name = "DB_NAME",              value = var.db_name },
        { name = "DB_USER",              value = var.db_username },
        { name = "REDIS_URL",            value = "redis://${var.redis_endpoint}:6379" },
        { name = "COGNITO_USER_POOL_ID", value = var.cognito_user_pool_id },
        { name = "COGNITO_CLIENT_ID",    value = var.cognito_client_id },
        { name = "CDN_URL",              value = var.cdn_url },
        { name = "AWS_REGION",           value = var.region },
        { name = "ASSETS_BUCKET",        value = var.assets_bucket_name },
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.db_secret_arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      # Prevent OOM kills from crashing neighboring containers
      ulimits = [{
        name      = "nofile"
        softLimit = 65536
        hardLimit = 65536
      }]
    },
    {
      # Sidecar: AWS X-Ray daemon for distributed tracing
      name      = "xray-daemon"
      image     = "public.ecr.aws/xray/aws-xray-daemon:latest"
      essential = false
      portMappings = [{
        containerPort = 2000
        protocol      = "udp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "xray"
        }
      }
    }
  ])

  tags = { Name = "${var.name_prefix}-api-task" }
}

# ── Security Groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Allow HTTP/HTTPS from internet to ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet"
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb-sg" }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks-sg"
  description = "Allow traffic from ALB to ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "From ALB only"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-ecs-tasks-sg" }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "api" {
  name               = "${var.name_prefix}-api-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod"
  enable_http2               = true

  access_logs {
    bucket  = "${var.name_prefix}-pipeline-artifacts-${var.account_id}"
    prefix  = "alb-logs"
    enabled = true
  }

  tags = { Name = "${var.name_prefix}-api-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name_prefix}-api-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"  # Required for Fargate awsvpc networking

  health_check {
    enabled             = true
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30  # Fast deregistration for zero-downtime deploys

  tags = { Name = "${var.name_prefix}-api-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect all HTTP → HTTPS
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  # certificate_arn = var.certificate_arn  # Uncomment when cert is available

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count

  # Use both regular and Spot capacity
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 2
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 8
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  # Rolling update — always keep at least 50% of tasks running during deploy
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true  # Automatically roll back on failed deployments
  }

  enable_execute_command = true  # Allows `aws ecs execute-command` for debugging

  depends_on = [aws_lb_listener.https]

  lifecycle {
    # Don't reset desired_count if auto-scaler changed it
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.name_prefix}-api-service" }
}

# ── Auto Scaling ──────────────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "api" {
  max_capacity       = var.api_max_count
  min_capacity       = var.api_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale out when CPU > 70%
resource "aws_appautoscaling_policy" "cpu_scale_out" {
  name               = "${var.name_prefix}-cpu-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Scale out when memory > 80%
resource "aws_appautoscaling_policy" "memory_scale_out" {
  name               = "${var.name_prefix}-memory-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"          { type = string }
variable "environment"          { type = string }
variable "vpc_id"               { type = string }
variable "public_subnet_ids"    { type = list(string) }
variable "private_subnet_ids"   { type = list(string) }
variable "account_id"           { type = string }
variable "region"               { type = string }
variable "api_image"            { type = string }
variable "api_cpu"              { type = number; default = 512 }
variable "api_memory"           { type = number; default = 1024 }
variable "api_desired_count"    { type = number; default = 2 }
variable "api_min_count"        { type = number; default = 1 }
variable "api_max_count"        { type = number; default = 10 }
variable "db_host"              { type = string }
variable "db_name"              { type = string }
variable "db_username"          { type = string }
variable "db_secret_arn"        { type = string }
variable "redis_endpoint"       { type = string }
variable "cognito_user_pool_id" { type = string }
variable "cognito_client_id"    { type = string }
variable "assets_bucket_name"   { type = string }
variable "cdn_url"              { type = string }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cluster_name"     { value = aws_ecs_cluster.main.name }
output "cluster_arn"      { value = aws_ecs_cluster.main.arn }
output "api_service_name" { value = aws_ecs_service.api.name }
output "alb_dns_name"     { value = aws_lb.api.dns_name }
output "alb_arn"          { value = aws_lb.api.arn }
output "ecr_url"          { value = aws_ecr_repository.api.repository_url }
output "task_sg_id"       { value = aws_security_group.ecs_tasks.id }
