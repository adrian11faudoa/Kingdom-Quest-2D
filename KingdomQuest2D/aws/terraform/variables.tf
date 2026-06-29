# =============================================================================
# Kingdom Quest 2D — Terraform Variable Definitions
# =============================================================================

# ── Core ──────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "domain_name" {
  description = "Primary domain name (e.g. kingdomquest2d.com)"
  type        = string
  default     = "kingdomquest2d.com"
}

variable "acm_certificate_arn" {
  description = "ARN of ACM TLS certificate (must be in us-east-1 for CloudFront)"
  type        = string
  default     = ""  # Leave empty to skip custom domain on CloudFront
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to deploy into (min 2 for HA)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# ── Database ──────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"
  # prod recommendation: db.r6g.large
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "kq2d_admin"
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL master password — override via TF_VAR_db_password env var"
  type        = string
  sensitive   = true
}

# ── Cache ─────────────────────────────────────────────────────────────────────

variable "cache_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.micro"
  # prod recommendation: cache.r6g.large
}

# ── ECS / API ─────────────────────────────────────────────────────────────────

variable "api_docker_image" {
  description = "Full ECR image URI for the game API (account.dkr.ecr.region.amazonaws.com/kq2d-api:tag)"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:latest"  # Placeholder until first build
}

variable "api_cpu" {
  description = "Fargate task CPU units (256=0.25vCPU, 512=0.5vCPU, 1024=1vCPU)"
  type        = number
  default     = 512
}

variable "api_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 1024
}

variable "api_desired_count" {
  description = "Desired number of API task replicas"
  type        = number
  default     = 2
}

variable "api_min_count" {
  description = "Minimum replicas (auto-scaling floor)"
  type        = number
  default     = 1
}

variable "api_max_count" {
  description = "Maximum replicas (auto-scaling ceiling)"
  type        = number
  default     = 10
}

# ── Auth ──────────────────────────────────────────────────────────────────────

variable "cognito_callback_urls" {
  description = "OAuth2 callback URLs for Cognito Hosted UI"
  type        = list(string)
  default     = ["https://kingdomquest2d.com/auth/callback", "http://localhost:3000/auth/callback"]
}

# ── Monitoring ────────────────────────────────────────────────────────────────

variable "alert_email" {
  description = "Email address for CloudWatch alarm SNS notifications"
  type        = string
  default     = "ops@kingdomquest2d.com"
}
