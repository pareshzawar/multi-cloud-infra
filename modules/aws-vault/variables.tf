###############################################################################
# modules/aws-vault/variables.tf
# Variable interface for the NAT-free Vault module (feat/remove-nat-gateway)
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the vault VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (EC2 now lives here, outbound via IGW)"
  type        = string
  default     = "172.16.1.0/24"
}

variable "availability_zone" {
  description = "AZ for the public subnet and EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for Vaultwarden (free-tier: t2.micro or t3.micro)"
  type        = string
  default     = "t3.micro"
}

variable "backup_bucket_name" {
  description = "Name of the S3 bucket for encrypted Vaultwarden backups (AES256)"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable auth key for joining the mesh"
  type        = string
  sensitive   = true
}

variable "tailscale_hostname" {
  description = "Tailscale hostname for the vault node (e.g. aws-vault)"
  type        = string
  default     = "aws-vault"
}

variable "aws_region" {
  description = "AWS region for the vault deployment"
  type        = string
  default     = "ap-south-1"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
