variable "aws_region" { type = string }
variable "ssh_public_key" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidr" { type = string }
variable "private_subnet_cidr" { type = string }
variable "domain_name" { type = string }
variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
variable "backup_bucket_name" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
