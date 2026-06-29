# =============================================================================
# Kingdom Quest 2D — AWS Infrastructure Root
# =============================================================================
# Orchestrates every AWS module needed to run the game backend:
#   VPC → RDS (player data) → ElastiCache (leaderboard/sessions)
#   → ECS Fargate (game API) → S3+CloudFront (game builds/assets)
#   → Cognito (auth) → Lambda (serverless events) → CloudWatch (monitoring)
#
# USAGE:
#   cd aws/terraform/environments/prod
#   terraform init
#   terraform plan -var-file="prod.tfvars"
#   terraform apply -var-file="prod.tfvars"
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Remote state — store in S3 so the team shares state
  backend "s3" {
    bucket         = "kingdom-quest-2d-tfstate"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "kingdom-quest-2d-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "KingdomQuest2D"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Local values ──────────────────────────────────────────────────────────────

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  name_prefix = "kq2d-${var.environment}"
}

# ── Modules ───────────────────────────────────────────────────────────────────

module "vpc" {
  source      = "../../modules/vpc"
  name_prefix = local.name_prefix
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  azs         = var.availability_zones
}

module "s3" {
  source      = "../../modules/s3"
  name_prefix = local.name_prefix
  environment = var.environment
  account_id  = local.account_id
}

module "cloudfront" {
  source              = "../../modules/cloudfront"
  name_prefix         = local.name_prefix
  environment         = var.environment
  assets_bucket_id    = module.s3.assets_bucket_id
  assets_bucket_arn   = module.s3.assets_bucket_arn
  assets_bucket_domain = module.s3.assets_bucket_domain
  builds_bucket_domain = module.s3.builds_bucket_domain
  builds_bucket_arn    = module.s3.builds_bucket_arn
  certificate_arn      = var.acm_certificate_arn
  domain_name          = var.domain_name
}

module "cognito" {
  source      = "../../modules/cognito"
  name_prefix = local.name_prefix
  environment = var.environment
  domain_name = var.domain_name
  callback_urls = var.cognito_callback_urls
}

module "rds" {
  source              = "../../modules/rds"
  name_prefix         = local.name_prefix
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  db_instance_class   = var.db_instance_class
  db_name             = "kingdom_quest"
  db_username         = var.db_username
  db_password         = var.db_password
  allowed_cidr_blocks = [var.vpc_cidr]
}

module "elasticache" {
  source             = "../../modules/elasticache"
  name_prefix        = local.name_prefix
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  node_type          = var.cache_node_type
  allowed_cidr_blocks = [var.vpc_cidr]
}

module "ecs" {
  source              = "../../modules/ecs"
  name_prefix         = local.name_prefix
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  account_id          = local.account_id
  region              = local.region

  # API service config
  api_image           = var.api_docker_image
  api_cpu             = var.api_cpu
  api_memory          = var.api_memory
  api_desired_count   = var.api_desired_count
  api_min_count       = var.api_min_count
  api_max_count       = var.api_max_count

  # Secrets & endpoints passed as env vars to containers
  db_host             = module.rds.db_endpoint
  db_name             = "kingdom_quest"
  db_username         = var.db_username
  db_secret_arn       = module.rds.db_secret_arn
  redis_endpoint      = module.elasticache.redis_endpoint
  cognito_user_pool_id = module.cognito.user_pool_id
  cognito_client_id    = module.cognito.client_id

  assets_bucket_name  = module.s3.assets_bucket_id
  cdn_url             = module.cloudfront.cdn_url
}

module "lambda" {
  source      = "../../modules/lambda"
  name_prefix = local.name_prefix
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_secret_arn      = module.rds.db_secret_arn
  redis_endpoint     = module.elasticache.redis_endpoint
  account_id         = local.account_id
  region             = local.region
}

module "monitoring" {
  source          = "../../modules/monitoring"
  name_prefix     = local.name_prefix
  environment     = var.environment
  ecs_cluster_name = module.ecs.cluster_name
  api_service_name = module.ecs.api_service_name
  rds_identifier   = module.rds.db_identifier
  alert_email      = var.alert_email
  account_id       = local.account_id
  region           = local.region
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cdn_url" {
  description = "CloudFront CDN URL for game assets and builds"
  value       = module.cloudfront.cdn_url
}

output "api_load_balancer_dns" {
  description = "Application Load Balancer DNS for the game API"
  value       = module.ecs.alb_dns_name
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for player authentication"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "Cognito App Client ID"
  value       = module.cognito.client_id
}

output "assets_bucket_name" {
  description = "S3 bucket name for game assets"
  value       = module.s3.assets_bucket_id
}

output "builds_bucket_name" {
  description = "S3 bucket name for game builds"
  value       = module.s3.builds_bucket_id
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = module.elasticache.redis_endpoint
  sensitive   = true
}
