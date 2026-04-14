###############################################################################
# modules/oci-micro2/outputs.tf
###############################################################################

output "instance_id" {
  description = "OCI Micro #2 instance OCID"
  value       = oci_core_instance.micro2.id
}

output "private_ip" {
  description = "Private IP on OCI VCN — reachable directly from Ampere A1"
  value       = oci_core_instance.micro2.private_ip
}

output "display_name" {
  description = "Instance display name"
  value       = oci_core_instance.micro2.display_name
}

output "uptime_kuma_internal_url" {
  description = "Uptime Kuma URL via Tailscale (access after connecting VPN/Tailscale)"
  value       = "http://${oci_core_instance.micro2.private_ip}:3001  (via Tailscale only)"
}

output "portainer_internal_url" {
  description = "Portainer URL via Tailscale"
  value       = "http://${oci_core_instance.micro2.private_ip}:9000  (via Tailscale only)"
}
