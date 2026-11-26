# cluster-secrets-reader: the identity External Secrets Operator uses in the
# OKE cluster (ClusterSecretStore "oci-vault", k8s-free-gitops repo) to read OCI Vault.
#
# It may only read secrets of the one vault this stack creates, nothing else.
# Its API signing key is made on your laptop by scripts/make-reader-key.sh:
# only the public half goes to Oracle (oci CLI upload), so no private key is
# ever in OpenTofu state. The private half goes straight into the cluster
# repo's one remaining SOPS secret (external-secrets/oci-vault-reader).

resource "oci_identity_domains_user" "secrets_reader" {
  idcs_endpoint = local.idcs_endpoint
  user_name     = "cluster-secrets-reader"
  description   = "External Secrets Operator in oke-free: read-only on the secrets of vault freetier"
  active        = true
  schemas = [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:capabilities:User",
  ]

  name {
    family_name = "cluster-secrets-reader"
  }

  emails {
    primary = true
    type    = "work"
    value   = var.alert_email
  }

  # API signing keys (max 3 per user) and nothing else: no console login,
  # no auth tokens, no S3 keys.
  urnietfparamsscimschemasoracleidcsextensioncapabilities_user {
    can_use_api_keys                 = true
    can_use_auth_tokens              = false
    can_use_console_password         = false
    can_use_customer_secret_keys     = false
    can_use_db_credentials           = false
    can_use_oauth2client_credentials = false
    can_use_smtp_credentials         = false
  }
  # Same as the S3 users in identity.tf: Oracle adds schemas and a recovery email.
  lifecycle {
    ignore_changes = [schemas, emails]
  }
}

resource "oci_identity_group" "secrets_reader" {
  compartment_id = var.tenancy_ocid
  name           = "cluster-secrets-reader"
  description    = "Reads the secrets of vault freetier (External Secrets in oke-free)"
}

resource "oci_identity_user_group_membership" "secrets_reader" {
  group_id = oci_identity_group.secrets_reader.id
  user_id  = oci_identity_domains_user.secrets_reader.ocid
}

# read secret-bundles = the secret contents (GetSecretBundle/ByName,
# permission SECRET_BUNDLE_READ); read secrets = their metadata (names,
# versions). Both only for this vault.
resource "oci_identity_policy" "secrets_reader" {
  compartment_id = local.compartment_id
  name           = "cluster-secrets-reader"
  description    = "External Secrets in oke-free reads the secrets of vault freetier, nothing else."
  statements = [
    "Allow group id ${oci_identity_group.secrets_reader.id} to read secret-bundles in compartment id ${local.compartment_id} where target.vault.id = '${oci_kms_vault.this.id}'",
    "Allow group id ${oci_identity_group.secrets_reader.id} to read secrets in compartment id ${local.compartment_id} where target.vault.id = '${oci_kms_vault.this.id}'",
  ]
}
