# Names in capitals become GitHub Actions variables (scripts/bootstrap.sh).
output "OCI_TENANCY_OCID" {
  value = var.tenancy_ocid
}

output "OCI_REGION" {
  value = var.region
}

output "OCI_COMPARTMENT_OCID" {
  value = local.compartment_id
}

output "OCI_NAMESPACE" {
  value = local.namespace
}

output "OCI_OIDC_DOMAIN_URL" {
  value = local.idcs_endpoint
}

output "OCI_OIDC_CLIENT_ID" {
  value = oci_identity_domains_app.github.name
}

output "OCI_VAULT_OCID" {
  value = oci_kms_vault.this.id
}

output "OCI_VAULT_KEY_OCID" {
  value = oci_kms_key.secrets.id
}

output "oidc_client_secret" {
  description = "Goes into the GitHub secret OCI_OIDC_CLIENT_SECRET (bootstrap.sh does it)."
  value       = oci_identity_domains_app.github.client_secret
  sensitive   = true
}

output "s3_endpoint" {
  value = "https://${local.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "s3_access_keys" {
  description = "S3 access key ids of backup and zot (not secret)."
  value       = { for k, v in oci_identity_customer_secret_key.s3 : k => v.id if k != "tfstate" }
}

output "s3_secret_keys" {
  description = "tofu output -json s3_secret_keys (backup and zot)"
  value       = { for k, v in oci_identity_customer_secret_key.s3 : k => v.key if k != "tfstate" }
  sensitive   = true
}

# The state key: scripts/bootstrap.sh copies it into GitHub secrets and the
# laptop profile oracle-tfstate (scripts/tfstate-profile.sh). Never print it.
output "tfstate_access_key_id" {
  description = "Access key id of s3-tfstate (GitHub secret OCI_STATE_ACCESS_KEY_ID)."
  value       = oci_identity_customer_secret_key.s3["tfstate"].id
  sensitive   = true
}

output "tfstate_secret_key" {
  description = "Secret key of s3-tfstate (GitHub secret OCI_STATE_SECRET_ACCESS_KEY)."
  value       = oci_identity_customer_secret_key.s3["tfstate"].key
  sensitive   = true
}

output "cluster_secrets_reader_ocid" {
  description = "OCID of cluster-secrets-reader (scripts/make-reader-key.sh uploads its API key; cluster setting OCI_VAULT_READER_OCID)."
  value       = oci_identity_domains_user.secrets_reader.ocid
}
