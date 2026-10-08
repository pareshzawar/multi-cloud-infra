variable "compartment_id" { type = string }
variable "availability_domain" { type = string }
variable "ssh_public_key" { type = string }
variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
variable "tags" { type = map(string) }

variable "backup_bucket_name" {
  description = "AWS S3 bucket holding the Vaultwarden db-YYYY-MM-DD.sqlite3 snapshots (written by modules/aws-vault)"
  type        = string
}
