###############################################################################
# modules/azure-sso/main.tf
# Azure Entra ID OIDC app registrations
#
# PREREQUISITE — This module requires Application Administrator role.
# With a personal @live.com account, run FIRST:
#
#   az login --tenant YOUR_TENANT_ID --allow-no-subscriptions
#   az ad sp create-for-rbac --name "terraform-sp" --role "Application.ReadWrite.All"
#
# If that still fails, set var.create_apps = false and create apps manually
# in portal.azure.com — see MANUAL_SETUP.md in the repo root.
#
# The manual steps are documented in MANUAL_SETUP.md
###############################################################################

variable "create_apps" {
  description = "Set false to skip app creation (use manual portal setup instead)"
  type        = bool
  default     = false
}

data "azuread_client_config" "current" {}

# ── n8n ──────────────────────────────────────────────────────────────────────

resource "azuread_application" "n8n" {
  count            = var.create_apps ? 1 : 0
  display_name     = "n8n Workflow Automation"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [var.n8n_redirect_uri]
    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "n8n" {
  count                        = var.create_apps ? 1 : 0
  client_id                    = azuread_application.n8n[0].client_id
  app_role_assignment_required = false
}

resource "azuread_application_password" "n8n" {
  count          = var.create_apps ? 1 : 0
  application_id = azuread_application.n8n[0].id
  display_name   = "n8n-client-secret"
  end_date       = "2027-01-01T00:00:00Z"
}

# ── Uptime Kuma ───────────────────────────────────────────────────────────────

resource "azuread_application" "uptime_kuma" {
  count            = var.create_apps ? 1 : 0
  display_name     = "Uptime Kuma Monitoring"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [var.uptime_kuma_redirect_uri]
    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "uptime_kuma" {
  count                        = var.create_apps ? 1 : 0
  client_id                    = azuread_application.uptime_kuma[0].client_id
  app_role_assignment_required = false
}

resource "azuread_application_password" "uptime_kuma" {
  count          = var.create_apps ? 1 : 0
  application_id = azuread_application.uptime_kuma[0].id
  display_name   = "uptime-kuma-secret"
  end_date       = "2027-01-01T00:00:00Z"
}

# ── WireGuard ─────────────────────────────────────────────────────────────────

resource "azuread_application" "wireguard" {
  count            = var.create_apps ? 1 : 0
  display_name     = "WireGuard Admin UI"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [var.wg_redirect_uri]
    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "wireguard" {
  count                        = var.create_apps ? 1 : 0
  client_id                    = azuread_application.wireguard[0].client_id
  app_role_assignment_required = false
}

resource "azuread_application_password" "wireguard" {
  count          = var.create_apps ? 1 : 0
  application_id = azuread_application.wireguard[0].id
  display_name   = "wireguard-admin-secret"
  end_date       = "2027-01-01T00:00:00Z"
}
