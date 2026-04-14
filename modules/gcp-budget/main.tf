###############################################################################
# modules/gcp-budget/main.tf
# GCP Billing Budget + email notification
#
# MANUAL STEP REQUIRED (cannot be fully automated without billing admin role):
#   gcloud billing accounts list  -- get your billing account ID
#   gcloud services enable billingbudgets.googleapis.com --project=YOUR_PROJECT
#   gcloud auth application-default set-quota-project YOUR_PROJECT_ID
#
# The google_billing_budget resource requires:
#   1. billingbudgets.googleapis.com API enabled
#   2. roles/billing.costsManager on the billing account
###############################################################################

resource "google_pubsub_topic" "budget_alert" {
  name    = "billing-budget-alert"
  project = var.project_id
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "billing-alert-email"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.alert_email
  }
}

# Budget resource — requires billing admin role on the billing account
# If this fails with 403, see MANUAL STEPS in README
resource "google_billing_budget" "monthly" {
  # billing_account must be just the ID, e.g. "012345-6789AB-CDEF01"
  # Get it with: gcloud billing accounts list
  billing_account = var.billing_account_id
  display_name    = "monthly-cost-alert"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "INR"
      units         = "1"
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.name]
    disable_default_iam_recipients   = false
  }
}
