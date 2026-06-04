output "instance_id" { value = aws_instance.vault.id }
output "private_ip" { value = aws_instance.vault.private_ip }
output "tailscale_ip" {
  #value       = "run: ssh ubuntu@<private_ip> then: tailscale ip -4"
  value       = "100.82.194.62"
  description = "Get this after deploy: SSH into instance, run: tailscale ip -4"
}
output "backup_bucket" { value = aws_s3_bucket.backup.id }
output "vpc_id" { value = aws_vpc.vault.id }
