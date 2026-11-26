# Keyless GitHub Actions login (Workload Identity Federation).
#
# GitHub's OIDC token is exchanged at the identity domain for a 60-minute
# Oracle session token (UPST) of a service user. Which user depends on where
# the workflow runs:
#   pull requests      -> <repo>-plan  (read only)
#   main (push, manual) -> <repo>-apply (manages the freetier compartment)
# Anything that runs on main was merged by you; PR code only ever gets read access.
#
# These identities drive the OCI provider only. The state is reached with the
# S3 key of user s3-tfstate below (OpenTofu has no oci backend).

data "oci_identity_domains" "default" {
  compartment_id = var.tenancy_ocid
  display_name   = "Default"
}

locals {
  idcs_endpoint = trimsuffix(one(data.oci_identity_domains.default.domains).url, ":443")

  # GitHub's immutable subjects carry the owner and repo IDs
  # (repo:Owner@123/name@456:...); scripts/bootstrap.sh reads the prefix from
  # GitHub so the rules match the tokens exactly.
  sub_prefix = var.github_sub_prefix != "" ? var.github_sub_prefix : "repo:${var.github_repository}"
  ci_identities = {
    plan  = "${local.sub_prefix}:pull_request"
    apply = "${local.sub_prefix}:ref:refs/heads/main"
  }
}

resource "oci_identity_domains_user" "ci" {
  for_each = local.ci_identities

  idcs_endpoint = local.idcs_endpoint
  user_name     = "${local.repo_name}-${each.key}"
  active        = true
  schemas = [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:capabilities:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:user:User",
  ]
  attributes = join(",", [
    "id", "ocid", "userName", "active", "schemas",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:capabilities:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:user:User.serviceUser",
  ])

  # Session tokens only: no keys, passwords or tokens of its own.
  urnietfparamsscimschemasoracleidcsextensioncapabilities_user {
    can_use_api_keys                 = false
    can_use_auth_tokens              = false
    can_use_console_password         = false
    can_use_customer_secret_keys     = false
    can_use_db_credentials           = false
    can_use_oauth2client_credentials = false
    can_use_smtp_credentials         = false
  }

  urnietfparamsscimschemasoracleidcsextensionuser_user {
    service_user = true
  }
}

resource "oci_identity_group" "ci" {
  for_each = local.ci_identities

  compartment_id = var.tenancy_ocid
  name           = "${local.repo_name}-${each.key}"
  description    = "GitHub Actions ${each.key} identity for ${var.github_repository}"
}

resource "oci_identity_user_group_membership" "ci" {
  for_each = local.ci_identities

  group_id = oci_identity_group.ci[each.key].id
  user_id  = oci_identity_domains_user.ci[each.key].ocid
}

resource "oci_identity_policy" "ci_tenancy" {
  compartment_id = var.tenancy_ocid
  name           = "${local.repo_name}-ci-tenancy"
  description    = "What CI needs outside the freetier compartment: discovery only."
  statements = flatten([
    for k, _ in local.ci_identities : [
      "Allow group id ${oci_identity_group.ci[k].id} to inspect compartments in tenancy",
      "Allow group id ${oci_identity_group.ci[k].id} to read objectstorage-namespaces in tenancy",
    ]
  ])
}

resource "oci_identity_policy" "ci_compartment" {
  compartment_id = local.compartment_id
  name           = "${local.repo_name}-ci"
  description    = "GitHub Actions permissions in the freetier compartment."
  statements = [
    # plan: read everything except secret contents.
    "Allow group id ${oci_identity_group.ci["plan"].id} to read all-resources in compartment id ${local.compartment_id} where request.permission != 'SECRET_BUNDLE_READ'",
    # apply: manage the compartment (network, cluster, VMs, bastion, secrets).
    "Allow group id ${oci_identity_group.ci["apply"].id} to manage all-resources in compartment id ${local.compartment_id}",
  ]
}

resource "oci_identity_domains_app" "github" {
  idcs_endpoint   = local.idcs_endpoint
  display_name    = "github-${local.repo_name}"
  description     = "OAuth client used by ${var.github_repository} to exchange GitHub OIDC tokens"
  active          = true
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  is_oauth_client = true
  client_type     = "confidential"
  allowed_grants  = ["client_credentials"]

  based_on_template {
    value = "CustomWebAppTemplateId"
  }
  # Oracle adds the OCITags schema after creation.
  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_identity_propagation_trust" "github" {
  idcs_endpoint = local.idcs_endpoint
  name          = "github-${local.repo_name}"
  description   = "GitHub Actions OIDC tokens from ${var.github_repository}"
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"]
  type          = "JWT"
  active        = true

  issuer              = "https://token.actions.githubusercontent.com"
  public_key_endpoint = "https://token.actions.githubusercontent.com/.well-known/jwks"
  oauth_clients       = [oci_identity_domains_app.github.name]

  # Only tokens minted for this repository are accepted at all.
  client_claim_name   = "repository"
  client_claim_values = [var.github_repository]

  subject_claim_name  = "sub"
  subject_type        = "User"
  allow_impersonation = true

  dynamic "impersonation_service_users" {
    for_each = local.ci_identities
    content {
      rule  = "sub eq ${impersonation_service_users.value}"
      value = oci_identity_domains_user.ci[impersonation_service_users.key].id
    }
  }

  # The impersonation mappings are only returned when asked for explicitly.
  attributes = join(",", [
    "id", "name", "description", "schemas", "type", "active", "issuer",
    "publicKeyEndpoint", "oauthClients", "clientClaimName", "clientClaimValues",
    "subjectClaimName", "subjectType", "allowImpersonation", "impersonationServiceUsers",
  ])
}

# S3-compatible keys (customer secret keys), each user limited to one bucket:
#   backup  -> restic on the Home server and in the cluster (backups bucket)
#   zot     -> Zot in the cluster (zot bucket)
#   tfstate -> the OpenTofu state of bootstrap/ and infra/ (tfstate bucket).
#              OpenTofu has no oci backend, so both roots use the s3 backend on
#              Oracle's S3-compatible endpoint with this key. scripts/bootstrap.sh
#              puts it into the GitHub secrets OCI_STATE_ACCESS_KEY_ID /
#              OCI_STATE_SECRET_ACCESS_KEY and the laptop profile oracle-tfstate.
locals {
  s3_users = {
    backup  = "backups"
    zot     = "zot"
    tfstate = "tfstate"
  }
}

resource "oci_identity_domains_user" "s3" {
  for_each = local.s3_users

  idcs_endpoint = local.idcs_endpoint
  user_name     = "s3-${each.key}"
  active        = true
  schemas = [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:capabilities:User",
  ]

  name {
    family_name = "s3-${each.key}"
  }

  emails {
    primary = true
    type    = "work"
    value   = var.alert_email
  }

  # Customer secret keys (S3 access keys) and nothing else.
  urnietfparamsscimschemasoracleidcsextensioncapabilities_user {
    can_use_api_keys                 = false
    can_use_auth_tokens              = false
    can_use_console_password         = false
    can_use_customer_secret_keys     = true
    can_use_db_credentials           = false
    can_use_oauth2client_credentials = false
    can_use_smtp_credentials         = false
  }
  # Oracle adds schemas (OCITags, userState) and a recovery copy of the email
  # after creation; without this every run shows the same in-place update.
  lifecycle {
    ignore_changes = [schemas, emails]
  }
}

resource "oci_identity_group" "s3" {
  for_each = local.s3_users

  compartment_id = var.tenancy_ocid
  name           = "s3-${each.key}"
  description    = "S3 access to the ${each.value} bucket only"
}

resource "oci_identity_user_group_membership" "s3" {
  for_each = local.s3_users

  group_id = oci_identity_group.s3[each.key].id
  user_id  = oci_identity_domains_user.s3[each.key].ocid
}

resource "oci_identity_policy" "s3" {
  compartment_id = local.compartment_id
  name           = "s3-buckets"
  description    = "Each S3 user reaches its own bucket only."
  statements = flatten([
    for k, bucket in local.s3_users : [
      "Allow group id ${oci_identity_group.s3[k].id} to read buckets in compartment id ${local.compartment_id} where target.bucket.name = '${bucket}'",
      "Allow group id ${oci_identity_group.s3[k].id} to manage objects in compartment id ${local.compartment_id} where target.bucket.name = '${bucket}'",
    ]
  ])
}

# The secret half is only readable right after creation; it lives in this
# state (private, versioned bucket) and is shown with `tofu output`.
resource "oci_identity_customer_secret_key" "s3" {
  for_each = local.s3_users

  user_id      = oci_identity_domains_user.s3[each.key].ocid
  display_name = "s3-${each.key}"
}
