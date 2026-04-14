###############################################################################
# modules/oci-budget/main.tf
# OCI Budget — target_type must be COMPARTMENT (root compartment = tenancy)
# TENANCY is not a valid value in OCI provider v6+
###############################################################################

resource "oci_budget_budget" "main" {
  compartment_id = var.tenancy_id
  target_type    = "COMPARTMENT"    # TENANCY is invalid — use COMPARTMENT on root
  targets        = [var.tenancy_id] # Target the root compartment (= whole tenancy)
  amount         = var.threshold_usd
  reset_period   = "MONTHLY"
  display_name   = "monthly_cost_alert" # must match [a-zA-Z_][a-zA-Z_0-9]*
  description    = "Alert when monthly spend exceeds threshold"

  freeform_tags = var.tags
}

resource "oci_budget_alert_rule" "email_alert" {
  budget_id      = oci_budget_budget.main.id
  type           = "ACTUAL"
  threshold      = var.threshold_usd
  threshold_type = "ABSOLUTE"
  display_name   = "alert_at_1_dollar" # alphanumeric + underscore only
  description    = "Email alert when actual spend exceeds threshold"
  recipients     = var.alert_email
  message        = "WARNING: OCI tenancy has charges over the alert threshold. Check https://cloud.oracle.com/usage"
}
