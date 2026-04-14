output "budget_name" { value = google_billing_budget.monthly.display_name }
output "pubsub_topic" { value = google_pubsub_topic.budget_alert.name }
output "notification_channel" { value = google_monitoring_notification_channel.email.name }
