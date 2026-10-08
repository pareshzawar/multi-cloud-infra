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
  description = "Uptime Kuma, published to the tailnet by `tailscale serve` (tailnet members only)"
  value       = "https://oci-micro2-ops.<your-tailnet>.ts.net/"
}

output "portainer_internal_url" {
  description = "Portainer, published to the tailnet by `tailscale serve` (tailnet members only)"
  value       = "https://oci-micro2-ops.<your-tailnet>.ts.net:8443/"
}
