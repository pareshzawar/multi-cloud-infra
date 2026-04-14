variable "compartment_id" { type = string }
variable "availability_domain" { type = string }
variable "ssh_public_key" { type = string }
variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
variable "tags" { type = map(string) }

variable "domain_name" {
  description = "Root domain name for Vaultwarden DOMAIN env var"
  type        = string
  default     = "yourdomain.com"
}

variable "n8n_tailscale_ip" {
  description = "Tailscale IP of OCI A1 (for webhook relay to forward to n8n). Set after first deploy."
  type        = string
  default     = ""
}
