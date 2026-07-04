# =============================================================================
# Module: ElastiCache Redis
# In-memory cache for: session tokens, leaderboards, rate limiting,
# real-time player counts, pub/sub for multiplayer lobby signalling.
# Uses Redis 7 with cluster mode disabled (single shard, multi-AZ replica).
# =============================================================================

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Allow Redis from private subnets only"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Redis from VPC"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-redis-sg" }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-redis-subnet-group" }
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "${var.name_prefix}-redis7-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"  # Evict least recently used when memory full
  }
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"  # Keyspace notifications for expiry events (useful for sessions)
  }

  tags = { Name = "${var.name_prefix}-redis7-params" }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.name_prefix}-redis"
  description                = "Kingdom Quest 2D Redis cluster"

  node_type            = var.node_type
  num_cache_clusters   = var.environment == "prod" ? 2 : 1  # Replica in prod
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  # Encryption
  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = true  # TLS in transit

  # Automatic failover requires at least 2 nodes
  automatic_failover_enabled = var.environment == "prod"
  multi_az_enabled           = var.environment == "prod"

  # Maintenance
  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_window          = "04:00-05:00"
  snapshot_retention_limit = 3

  # Engine version
  engine_version = "7.1"

  apply_immediately = var.environment != "prod"

  tags = { Name = "${var.name_prefix}-redis" }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"         { type = string }
variable "environment"         { type = string }
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "node_type"           { type = string; default = "cache.t3.micro" }
variable "allowed_cidr_blocks" { type = list(string) }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "redis_endpoint"         { value = aws_elasticache_replication_group.main.primary_endpoint_address; sensitive = true }
output "redis_reader_endpoint"  { value = aws_elasticache_replication_group.main.reader_endpoint_address; sensitive = true }
output "redis_port"             { value = 6379 }
output "redis_sg_id"            { value = aws_security_group.redis.id }
