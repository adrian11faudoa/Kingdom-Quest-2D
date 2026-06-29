# =============================================================================
# Module: RDS PostgreSQL
# Multi-AZ PostgreSQL for player accounts, progress, inventory, leaderboards.
# Uses Secrets Manager for credentials — never stored in Terraform state.
# =============================================================================

# ── Random suffix for secret name (avoids deletion conflicts) ─────────────────

resource "random_id" "suffix" {
  byte_length = 4
}

# ── Credentials in Secrets Manager ───────────────────────────────────────────

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name_prefix}/rds/master-credentials-${random_id.suffix.hex}"
  description = "Kingdom Quest 2D RDS master credentials"

  recovery_window_in_days = 7  # Safety window before permanent deletion

  tags = { Name = "${var.name_prefix}-db-secret" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = var.db_name
  })

  # Update secret when DB endpoint changes
  depends_on = [aws_db_instance.main]
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow PostgreSQL from private subnets only"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "PostgreSQL from VPC"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-db-subnet-group" }
}

# ── Parameter Group (performance tuning) ─────────────────────────────────────

resource "aws_db_parameter_group" "main" {
  name   = "${var.name_prefix}-pg16-params"
  family = "postgres16"

  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"  # Log queries slower than 1 second
  }
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"  # Enable query statistics
  }
  parameter {
    name         = "max_connections"
    value        = "200"
    apply_method = "pending-reboot"
  }

  tags = { Name = "${var.name_prefix}-pg16-params" }
}

# ── RDS Instance ──────────────────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-postgres"

  # Engine
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.db_instance_class

  # Storage — gp3 is cheaper and faster than gp2
  allocated_storage     = 20
  max_allocated_storage = 500   # Auto-scale up to 500GB
  storage_type          = "gp3"
  storage_encrypted     = true

  # Credentials
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Availability
  multi_az = var.environment == "prod"  # Multi-AZ in prod only

  # Backup & maintenance
  backup_retention_period   = 7
  backup_window             = "03:00-04:00"  # UTC — low traffic window
  maintenance_window        = "sun:04:00-sun:05:00"
  delete_automated_backups  = false
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = "${var.name_prefix}-final-snapshot"

  # Monitoring
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60   # Enhanced monitoring every 60s
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  parameter_group_name = aws_db_parameter_group.main.name

  # Prevent accidental destruction of production database
  deletion_protection = var.environment == "prod"

  tags = { Name = "${var.name_prefix}-postgres" }
}

# ── Read Replica (prod only, for reporting/analytics queries) ─────────────────

resource "aws_db_instance" "replica" {
  count = var.environment == "prod" ? 1 : 0

  identifier     = "${var.name_prefix}-postgres-replica"
  instance_class = var.db_instance_class
  replicate_source_db = aws_db_instance.main.identifier

  storage_encrypted = true
  publicly_accessible = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${var.name_prefix}-postgres-replica" }
}

# ── Enhanced Monitoring IAM Role ──────────────────────────────────────────────

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"          { type = string }
variable "environment"          { type = string }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "db_instance_class"    { type = string }
variable "db_name"              { type = string }
variable "db_username"          { type = string }
variable "db_password"          { type = string; sensitive = true }
variable "allowed_cidr_blocks"  { type = list(string) }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "db_endpoint"   { value = aws_db_instance.main.address; sensitive = true }
output "db_port"       { value = aws_db_instance.main.port }
output "db_identifier" { value = aws_db_instance.main.identifier }
output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "db_sg_id"      { value = aws_security_group.rds.id }
