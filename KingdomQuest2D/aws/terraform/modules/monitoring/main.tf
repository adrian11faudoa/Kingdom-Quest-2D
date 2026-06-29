# =============================================================================
# Module: Monitoring
# CloudWatch dashboards, alarms, and SNS alerts for every critical metric.
# =============================================================================

# ── SNS Alert Topic ───────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-ops-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = { Name = "${var.name_prefix}-ops-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── ECS Alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.name_prefix}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85.0
  alarm_description   = "ECS service CPU utilisation > 85% for 2 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.api_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "${var.name_prefix}-ecs-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 90.0
  alarm_description   = "ECS service memory > 90%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.api_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_task_count_low" {
  alarm_name          = "${var.name_prefix}-ecs-tasks-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ECS running task count dropped below 1 — possible outage"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.api_service_name
  }
}

# ── RDS Alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80.0
  alarm_description   = "RDS CPU > 80% for 3 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = var.rds_identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 180
  alarm_description   = "RDS connections > 180 (of 200 max)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = var.rds_identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120  # 5 GB in bytes
  alarm_description   = "RDS free storage < 5GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = var.rds_identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_latency" {
  alarm_name          = "${var.name_prefix}-rds-read-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 0.1  # 100ms
  alarm_description   = "RDS read latency > 100ms"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = var.rds_identifier }
}

# ── Custom Game Metrics ────────────────────────────────────────────────────────

# Log-based metric: 5xx errors from the API
resource "aws_cloudwatch_log_metric_filter" "api_5xx" {
  name           = "${var.name_prefix}-api-5xx-errors"
  log_group_name = "/ecs/${var.name_prefix}/api"
  pattern        = "[..., status_code=5*, ...]"

  metric_transformation {
    name          = "API5xxErrors"
    namespace     = "KingdomQuest2D/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name_prefix}-api-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "API5xxErrors"
  namespace           = "KingdomQuest2D/${var.environment}"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "More than 10 API 5xx errors in 1 minute"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}

# ── CloudWatch Dashboard ───────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-operations"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: ECS
      {
        type   = "metric"
        x      = 0; y = 0; width = 8; height = 6
        properties = {
          title  = "ECS API — CPU & Memory"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization",    "ClusterName", var.ecs_cluster_name, "ServiceName", var.api_service_name, { label = "CPU %" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.api_service_name, { label = "Memory %" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 8; y = 0; width = 8; height = 6
        properties = {
          title  = "ECS Running Tasks"
          period = 60
          stat   = "Average"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name, "ServiceName", var.api_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16; y = 0; width = 8; height = 6
        properties = {
          title  = "API 5xx Errors"
          period = 60
          stat   = "Sum"
          metrics = [
            ["KingdomQuest2D/${var.environment}", "API5xxErrors", { label = "5xx/min", color = "#d13212" }]
          ]
        }
      },
      # Row 2: RDS
      {
        type   = "metric"
        x      = 0; y = 6; width = 8; height = 6
        properties = {
          title  = "RDS — CPU & Connections"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization",       "DBInstanceIdentifier", var.rds_identifier, { label = "CPU %" }],
            ["AWS/RDS", "DatabaseConnections",  "DBInstanceIdentifier", var.rds_identifier, { label = "Connections", yAxis = "right" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8; y = 6; width = 8; height = 6
        properties = {
          title  = "RDS — Read/Write Latency"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "ReadLatency",  "DBInstanceIdentifier", var.rds_identifier, { label = "Read ms" }],
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.rds_identifier, { label = "Write ms" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16; y = 6; width = 8; height = 6
        properties = {
          title  = "RDS — Free Storage (GB)"
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_identifier]
          ]
        }
      }
    ]
  })
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"      { type = string }
variable "environment"      { type = string }
variable "ecs_cluster_name" { type = string }
variable "api_service_name" { type = string }
variable "rds_identifier"   { type = string }
variable "alert_email"      { type = string }
variable "account_id"       { type = string }
variable "region"           { type = string }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "alerts_topic_arn"  { value = aws_sns_topic.alerts.arn }
output "dashboard_url"     { value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}" }
