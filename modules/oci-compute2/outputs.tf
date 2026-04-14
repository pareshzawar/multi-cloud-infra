output "micro_a_instance_id" { value = oci_core_instance.micro_a.id }
output "micro_a_public_ip" { value = oci_core_instance.micro_a.public_ip }
output "micro_a_private_ip" { value = oci_core_instance.micro_a.private_ip }

output "micro_b_instance_id" { value = oci_core_instance.micro_b.id }
output "micro_b_public_ip" { value = oci_core_instance.micro_b.public_ip }
output "micro_b_private_ip" { value = oci_core_instance.micro_b.private_ip }
output "micro_b_role" {
  value = "Vaultwarden STANDBY + Webhook relay + Rclone backup. Promote to active with: docker compose up -d vaultwarden"
}

output "vcn_id" { value = oci_core_vcn.tenancy2.id }
output "subnet_cidr" { value = oci_core_subnet.tenancy2.cidr_block }
