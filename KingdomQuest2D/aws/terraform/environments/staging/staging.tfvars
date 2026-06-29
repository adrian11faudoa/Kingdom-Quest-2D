# =============================================================================
# Kingdom Quest 2D — Staging Environment Variables
# terraform apply -var-file="staging.tfvars"
# =============================================================================

environment        = "staging"
aws_region         = "us-east-1"
domain_name        = "staging.kingdomquest2d.com"
acm_certificate_arn = ""

vpc_cidr            = "10.2.0.0/16"
availability_zones  = ["us-east-1a", "us-east-1b"]

db_instance_class = "db.t3.small"
db_username       = "kq2d_admin"
# db_password → export TF_VAR_db_password="..."

cache_node_type   = "cache.t3.small"

# Staging: medium footprint to reflect prod behavior
api_cpu           = 512
api_memory        = 1024
api_desired_count = 1
api_min_count     = 1
api_max_count     = 5

api_docker_image  = "public.ecr.aws/nginx/nginx:latest"

cognito_callback_urls = [
  "https://staging.kingdomquest2d.com/auth/callback",
  "http://localhost:3000/auth/callback"
]

alert_email = "dev@kingdomquest2d.com"
