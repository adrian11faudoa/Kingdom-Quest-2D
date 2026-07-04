# =============================================================================
# Module: VPC
# Creates the network foundation: VPC, public/private subnets, IGW, NAT Gateway,
# route tables, and VPC Flow Logs for security auditing.
# =============================================================================

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# ── Internet Gateway (public traffic) ─────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

# Public subnets — ALB, NAT Gateways
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${var.azs[count.index]}", Tier = "public" }
}

# Private subnets — ECS tasks, RDS, ElastiCache, Lambda
resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.azs))
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name_prefix}-private-${var.azs[count.index]}", Tier = "private" }
}

# Database subnets — isolated tier for RDS
resource "aws_subnet" "database" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.azs) * 2)
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name_prefix}-db-${var.azs[count.index]}", Tier = "database" }
}

# ── Elastic IPs for NAT Gateways ──────────────────────────────────────────────

resource "aws_eip" "nat" {
  count  = length(var.azs)
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip-${count.index}" }
}

# ── NAT Gateways (one per AZ for HA) ─────────────────────────────────────────

resource "aws_nat_gateway" "main" {
  count         = length(var.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.name_prefix}-nat-${var.azs[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Public route table — default route via IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ, route via that AZ's NAT GW
resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = { Name = "${var.name_prefix}-rt-private-${var.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "database" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── VPC Flow Logs (security & compliance) ─────────────────────────────────────

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_log.arn

  tags = { Name = "${var.name_prefix}-vpc-flow-logs" }
}

resource "aws_cloudwatch_log_group" "flow_log" {
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = 30
}

resource "aws_iam_role" "flow_log" {
  name = "${var.name_prefix}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.name_prefix}-vpc-flow-log-policy"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"  { type = string }
variable "environment"  { type = string }
variable "vpc_cidr"     { type = string }
variable "azs"          { type = list(string) }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "vpc_id"              { value = aws_vpc.main.id }
output "public_subnet_ids"   { value = aws_subnet.public[*].id }
output "private_subnet_ids"  { value = aws_subnet.private[*].id }
output "database_subnet_ids" { value = aws_subnet.database[*].id }
output "vpc_cidr"            { value = aws_vpc.main.cidr_block }
