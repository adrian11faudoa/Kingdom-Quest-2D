# =============================================================================
# Kingdom Quest 2D — Development Environment Variables
# terraform apply -var-file="dev.tfvars"
# =============================================================================

environment        = "dev"
aws_region         = "us-east-1"
domain_name        = "dev.kingdomquest2d.com"
acm_certificate_arn = ""

vpc_cidr            = "10.1.0.0/16"
availability_zones  = ["us-east-1a", "us-east-1b"]  # 2 AZs for cost savings

db_instance_class = "db.t3.micro"
db_username       = "kq2d_admin"

cache_node_type   = "cache.t3.micro"

# Dev: minimum footprint
api_cpu           = 256
api_memory        = 512
api_desired_count = 1
api_min_count     = 1
api_max_count     = 3

api_docker_image  = "public.ecr.aws/nginx/nginx:latest"  # Placeholder

cognito_callback_urls = [
  "https://dev.kingdomquest2d.com/auth/callback",
  "http://localhost:3000/auth/callback",
  "http://localhost:8080/auth/callback"
]

alert_email = "dev@kingdomquest2d.com"
