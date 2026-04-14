output "bucket_name" { value = oci_objectstorage_bucket.tfstate.name }
output "namespace" { value = data.oci_objectstorage_namespace.ns.namespace }
output "access_key_id" { value = oci_identity_customer_secret_key.tfstate.id }
output "secret_key" {
  value     = oci_identity_customer_secret_key.tfstate.key
  sensitive = true
}
output "s3_endpoint" {
  value = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}
