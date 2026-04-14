output "public_ip" { value = oci_load_balancer_load_balancer.main.ip_address_details[0].ip_address }
output "lb_id" { value = oci_load_balancer_load_balancer.main.id }
output "wg_nlb_public_ip" { value = oci_network_load_balancer_network_load_balancer.wireguard.ip_addresses[0].ip_address }
