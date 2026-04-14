###############################################################################
# modules/aws-budget/main.tf
# AWS Billing Budget + CloudWatch alarm
# Alerts at $1 actual spend AND $1 forecast
###############################################################################

# SNS Topic for budget notifications
resource "aws_sns_topic" "budget_alert" {
  name = "billing-budget-alert"
  tags = {}
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.budget_alert.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Budget: Actual spend alert ────────────────────────────────────────────────

resource "aws_budgets_budget" "monthly_actual" {
  name              = "monthly-cost-alert-actual"
  budget_type       = "COST"
  limit_amount      = tostring(var.threshold_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100 # 100% of budget = $1
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alert.arn]
  }

  # Also alert at 50% of budget ($0.50) as early warning
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ── Budget: Forecasted spend alert ────────────────────────────────────────────

resource "aws_budgets_budget" "monthly_forecast" {
  name              = "monthly-cost-alert-forecast"
  budget_type       = "COST"
  limit_amount      = tostring(var.threshold_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alert.arn]
  }
}

# ── CloudWatch: Free tier usage alert ────────────────────────────────────────
# Alert when EC2 hours approach the 750-hour/month free tier limit

resource "aws_cloudwatch_metric_alarm" "ec2_hours" {
  alarm_name          = "ec2-free-tier-hours-warning"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400 # Daily
  statistic           = "Maximum"
  threshold           = var.threshold_usd
  alarm_description   = "AWS billing charges exceed $${var.threshold_usd}"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.budget_alert.arn]
  ok_actions    = [aws_sns_topic.budget_alert.arn]

  tags = {}
}

# ── Free Tier Expiry Reminder ─────────────────────────────────────────────────
# CloudWatch Event to remind 60 days before 12-month free tier expires
# NOTE: Set your account creation date in var.free_tier_expiry_date

resource "aws_cloudwatch_event_rule" "free_tier_reminder" {
  name                = "free-tier-expiry-reminder"
  description         = "Reminder to plan migration before AWS free tier expires"
  schedule_expression = "cron(0 9 1 * ? *)" # 9 AM UTC on 1st of every month

  tags = {}
}

resource "aws_cloudwatch_event_target" "free_tier_sns" {
  rule      = aws_cloudwatch_event_rule.free_tier_reminder.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.budget_alert.arn

  input = jsonencode({
    message = "Monthly reminder: Check AWS free tier usage. EC2 t3.micro free tier expires 12 months after account creation. Plan Vaultwarden migration to OCI before expiry."
    subject = "AWS Free Tier Monthly Check"
  })
}
