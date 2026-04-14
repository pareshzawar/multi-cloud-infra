variable "compartment_id" { type = string }
variable "availability_domain" { type = string }
variable "private_subnet_id" { type = string }
variable "compute_nsg_id" { type = string }
variable "ssh_public_key" { type = string }
variable "domain_name" { type = string }
variable "n8n_subdomain" { type = string }
variable "wg_subdomain" { type = string }
variable "azure_tenant_id" { type = string }
variable "n8n_oidc_client_id" { type = string }
variable "n8n_oidc_secret" {
  type      = string
  sensitive = true
}
variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
variable "wireguard_host_ip" { type = string }
variable "tags" { type = map(string) }
