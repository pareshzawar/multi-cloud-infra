output "sns_topic_arn" { value = aws_sns_topic.budget_alert.arn }
output "budget_actual_id" { value = aws_budgets_budget.monthly_actual.id }
output "budget_forecast_id" { value = aws_budgets_budget.monthly_forecast.id }
output "cloudwatch_alarm_name" { value = aws_cloudwatch_metric_alarm.ec2_hours.alarm_name }
