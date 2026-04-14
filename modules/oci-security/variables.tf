variable "compartment_id" { type = string }
variable "vcn_id" { type = string }
variable "public_subnet_id" { type = string }
variable "private_subnet_id" { type = string }
variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}
variable "admin_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "tags" {
  type    = map(string)
  default = {}
}
