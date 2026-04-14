variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "vpc_cidr" { type = string }
variable "ssh_public_key" { type = string }
variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
variable "oci_tailscale_ip" {
  type    = string
  default = ""
}
variable "domain_name" { type = string }
variable "uptime_kuma_subdomain" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
