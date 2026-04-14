output "vcn_id" { value = oci_core_vcn.main.id }
output "public_subnet_id" { value = oci_core_subnet.public.id }
output "private_subnet_id" { value = oci_core_subnet.private.id }
output "igw_id" { value = oci_core_internet_gateway.igw.id }
output "nat_gateway_id" { value = oci_core_nat_gateway.nat.id }
