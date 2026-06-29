# =============================================================================
# Module: Lambda
# Serverless functions for event-driven game backend tasks:
#   - leaderboard_update    : triggered by API, updates Redis sorted sets
#   - save_backup           : copies player saves to Glacier on schedule
#   - player_event_handler  : processes game events (quest complete, level up)
#   - daily_reset           : resets daily quests/challenges at midnight UTC
#   - analytics_processor   : aggregates game telemetry into CloudWatch metrics
# =============================================================================

# ── Common IAM Role ───────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [var.db_secret_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-player-saves-${var.account_id}/*",
          "arn:aws:s3:::${var.name_prefix}-player-saves-${var.account_id}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${var.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.game_events.arn
      }
    ]
  })
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda functions — outbound only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-lambda-sg" }
}

# ── SNS Topic for game events ─────────────────────────────────────────────────

resource "aws_sns_topic" "game_events" {
  name              = "${var.name_prefix}-game-events"
  kms_master_key_id = "alias/aws/sns"

  tags = { Name = "${var.name_prefix}-game-events-topic" }
}

# ── Lambda: Leaderboard Update ────────────────────────────────────────────────

data "archive_file" "leaderboard_update" {
  type        = "zip"
  output_path = "/tmp/leaderboard_update.zip"
  source {
    content  = file("${path.module}/../../lambda_src/leaderboard_update/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "leaderboard_update" {
  function_name    = "${var.name_prefix}-leaderboard-update"
  description      = "Updates Redis leaderboard sorted sets from game events"
  filename         = data.archive_file.leaderboard_update.output_path
  source_code_hash = data.archive_file.leaderboard_update.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      REDIS_ENDPOINT = var.redis_endpoint
      REDIS_PORT     = "6379"
      DB_SECRET_ARN  = var.db_secret_arn
      ENVIRONMENT    = var.environment
    }
  }

  tracing_config { mode = "Active" }  # X-Ray tracing

  tags = { Name = "${var.name_prefix}-leaderboard-update" }
}

resource "aws_cloudwatch_log_group" "leaderboard_update" {
  name              = "/aws/lambda/${aws_lambda_function.leaderboard_update.function_name}"
  retention_in_days = 14
}

# ── Lambda: Daily Reset ───────────────────────────────────────────────────────

data "archive_file" "daily_reset" {
  type        = "zip"
  output_path = "/tmp/daily_reset.zip"
  source {
    content  = file("${path.module}/../../lambda_src/daily_reset/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "daily_reset" {
  function_name    = "${var.name_prefix}-daily-reset"
  description      = "Resets daily quests, cooldowns, and rotating shop inventory"
  filename         = data.archive_file.daily_reset.output_path
  source_code_hash = data.archive_file.daily_reset.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  timeout          = 120
  memory_size      = 512

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      REDIS_ENDPOINT = var.redis_endpoint
      DB_SECRET_ARN  = var.db_secret_arn
      SNS_TOPIC_ARN  = aws_sns_topic.game_events.arn
      ENVIRONMENT    = var.environment
    }
  }

  tracing_config { mode = "Active" }

  tags = { Name = "${var.name_prefix}-daily-reset" }
}

# Schedule: Every day at 00:00 UTC
resource "aws_cloudwatch_event_rule" "daily_reset" {
  name                = "${var.name_prefix}-daily-reset-schedule"
  description         = "Trigger daily reset Lambda at midnight UTC"
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "daily_reset" {
  rule      = aws_cloudwatch_event_rule.daily_reset.name
  target_id = "DailyResetLambda"
  arn       = aws_lambda_function.daily_reset.arn
}

resource "aws_lambda_permission" "daily_reset" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.daily_reset.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_reset.arn
}

resource "aws_cloudwatch_log_group" "daily_reset" {
  name              = "/aws/lambda/${aws_lambda_function.daily_reset.function_name}"
  retention_in_days = 14
}

# ── Lambda: Save Backup ───────────────────────────────────────────────────────

data "archive_file" "save_backup" {
  type        = "zip"
  output_path = "/tmp/save_backup.zip"
  source {
    content  = file("${path.module}/../../lambda_src/save_backup/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "save_backup" {
  function_name    = "${var.name_prefix}-save-backup"
  description      = "Backs up player saves and verifies integrity"
  filename         = data.archive_file.save_backup.output_path
  source_code_hash = data.archive_file.save_backup.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  timeout          = 300
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN = var.db_secret_arn
      ENVIRONMENT   = var.environment
    }
  }

  tracing_config { mode = "Active" }
  tags = { Name = "${var.name_prefix}-save-backup" }
}

# Schedule: Every 6 hours
resource "aws_cloudwatch_event_rule" "save_backup" {
  name                = "${var.name_prefix}-save-backup-schedule"
  schedule_expression = "rate(6 hours)"
}

resource "aws_cloudwatch_event_target" "save_backup" {
  rule      = aws_cloudwatch_event_rule.save_backup.name
  target_id = "SaveBackupLambda"
  arn       = aws_lambda_function.save_backup.arn
}

resource "aws_lambda_permission" "save_backup" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.save_backup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.save_backup.arn
}

resource "aws_cloudwatch_log_group" "save_backup" {
  name              = "/aws/lambda/${aws_lambda_function.save_backup.function_name}"
  retention_in_days = 14
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"        { type = string }
variable "environment"        { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "db_secret_arn"      { type = string }
variable "redis_endpoint"     { type = string }
variable "account_id"         { type = string }
variable "region"             { type = string }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "leaderboard_update_arn" { value = aws_lambda_function.leaderboard_update.arn }
output "daily_reset_arn"        { value = aws_lambda_function.daily_reset.arn }
output "save_backup_arn"        { value = aws_lambda_function.save_backup.arn }
output "game_events_topic_arn"  { value = aws_sns_topic.game_events.arn }
