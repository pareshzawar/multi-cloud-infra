variable "account_id" { type = string }
variable "alert_email" { type = string }
variable "threshold_usd" {
  type    = number
  default = 1.00
}