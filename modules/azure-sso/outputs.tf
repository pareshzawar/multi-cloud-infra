output "n8n_client_id" {
  value = var.create_apps ? azuread_application.n8n[0].client_id : "SET_MANUALLY_FROM_PORTAL"
}
output "n8n_client_secret" {
  value     = var.create_apps ? azuread_application_password.n8n[0].value : "SET_MANUALLY_FROM_PORTAL"
  sensitive = true
}
output "uptime_kuma_client_id" {
  value = var.create_apps ? azuread_application.uptime_kuma[0].client_id : "SET_MANUALLY_FROM_PORTAL"
}
output "uptime_kuma_client_secret" {
  value     = var.create_apps ? azuread_application_password.uptime_kuma[0].value : "SET_MANUALLY_FROM_PORTAL"
  sensitive = true
}
output "wireguard_client_id" {
  value = var.create_apps ? azuread_application.wireguard[0].client_id : "SET_MANUALLY_FROM_PORTAL"
}
output "wireguard_client_secret" {
  value     = var.create_apps ? azuread_application_password.wireguard[0].value : "SET_MANUALLY_FROM_PORTAL"
  sensitive = true
}
output "oidc_issuer_url" {
  value = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
}
output "oidc_metadata_url" {
  value = "https://login.microsoftonline.com/${var.tenant_id}/v2.0/.well-known/openid-configuration"
}
