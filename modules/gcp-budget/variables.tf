variable "project_id" { type = string }
variable "billing_account_id" {
  type        = string
  description = "GCP Billing Account ID (format: XXXXXX-XXXXXX-XXXXXX). Get with: gcloud billing accounts list"
}
variable "alert_email" { type = string }
variable "threshold_usd" {
  type    = number
  default = 1.00
}
