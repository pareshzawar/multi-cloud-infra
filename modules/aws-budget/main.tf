###############################################################################
# modules/aws-budget/main.tf
# AWS Billing Budgets → email + SNS
# Alerts at 50% / 100% of $1 actual spend, and at $1 forecast
###############################################################################

# SNS Topic for budget notifications
resource "aws_sns_topic" "budget_alert" {
  name = "billing-budget-alert"
  tags = {}
}

# Without this policy AWS Budgets and EventBridge are not allowed to publish to
# the topic, so their SNS notifications were silently dropped. Scoped to this
# account via aws:SourceAccount.
resource "aws_sns_topic_policy" "budget_alert" {
  arn = aws_sns_topic.budget_alert.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowBudgetsAndEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = ["budgets.amazonaws.com", "events.amazonaws.com"] }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.budget_alert.arn
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
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

# (A CloudWatch "EstimatedCharges" alarm used to live here. AWS publishes that
#  metric ONLY in us-east-1, so an alarm in ap-south-1 could never fire. The
#  two budgets above already cover actual and forecast spend.)

# ── Free Tier Expiry Reminder ─────────────────────────────────────────────────
# Monthly EventBridge reminder → SNS (a fixed monthly nudge, not tied to the
# account's actual free-tier end date)

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
