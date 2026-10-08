output "lb_nsg_id" { value = oci_core_network_security_group.lb.id }
output "compute_nsg_id" { value = oci_core_network_security_group.compute.id }
output "micro2_nsg_id" { value = oci_core_network_security_group.micro2.id }
