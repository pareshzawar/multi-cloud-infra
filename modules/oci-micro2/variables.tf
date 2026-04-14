###############################################################################
# modules/oci-micro2/variables.tf
###############################################################################

variable "compartment_id" {
  description = "OCI Compartment OCID"
  type        = string
}

variable "availability_domain" {
  description = "OCI Availability Domain (same as A1 preferred for low-latency)"
  type        = string
}

variable "private_subnet_id" {
  description = "Same private subnet as Ampere A1 — enables direct internal IP comms"
  type        = string
}

variable "micro2_nsg_id" {
  description = "NSG ID for micro2 instance"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable auth key"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Root domain for Watchtower email sender address"
  type        = string
}

variable "alert_email" {
  description = "Email for Watchtower update notifications"
  type        = string
}

variable "a1_private_ip" {
  description = "Ampere A1 private IP — used to configure Portainer agent endpoint"
  type        = string
  default     = "" # Set after A1 deploy; Portainer endpoint added manually first time
}

variable "tags" {
  description = "Freeform tags"
  type        = map(string)
  default     = {}
}
