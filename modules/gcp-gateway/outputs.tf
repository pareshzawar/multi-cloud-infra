output "public_ip" { value = google_compute_address.gateway.address }
output "instance_id" { value = google_compute_instance.gateway.instance_id }
output "instance_name" { value = google_compute_instance.gateway.name }
