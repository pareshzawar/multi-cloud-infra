output "instance_id" { value = aws_instance.vault.id }
output "private_ip" { value = aws_instance.vault.private_ip }
output "tailscale_url" {
  description = "Vaultwarden over the tailnet (HTTPS via tailscale serve). Tailnet members only."
  value       = "https://${var.tailscale_hostname}.<your-tailnet>.ts.net"
}
output "backup_bucket" { value = aws_s3_bucket.backup.id }
output "vpc_id" { value = aws_vpc.vault.id }
