locals {
  repo_name = split("/", var.github_repository)[1]
}

resource "oci_identity_compartment" "freetier" {
  compartment_id = var.tenancy_ocid
  name           = "freetier"
  description    = "Everything managed by ${var.github_repository}"
  enable_delete  = false
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  namespace      = data.oci_objectstorage_namespace.this.namespace
  compartment_id = oci_identity_compartment.freetier.id

  # Buckets live here, not in infra/, so a CI apply can never delete them.
  # Always Free Object Storage: 20 GB in total.
  buckets = {
    tfstate           = "OpenTofu state for oracle-always-free"
    backups           = "restic repositories (restic/home, restic/cluster)"
    zot               = "Zot registry storage"
    openbao-snapshots = "Reserved for OpenBao snapshots"
  }
}

resource "oci_objectstorage_bucket" "this" {
  for_each = local.buckets

  compartment_id = local.compartment_id
  namespace      = local.namespace
  name           = each.key
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = contains(["tfstate", "backups"], each.key) ? "Enabled" : "Disabled"
  freeform_tags  = { purpose = each.value }
}

# Lifecycle rules run as Oracle's Object Storage service, not as you, so the
# service needs its own permission on the objects (else 400
# InsufficientServicePermissions).
resource "oci_identity_policy" "objectstorage_service" {
  compartment_id = local.compartment_id
  name           = "objectstorage-lifecycle"
  description    = "Lets Object Storage run the lifecycle rules of the freetier buckets."
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in compartment id ${local.compartment_id}",
  ]
}

# Keep 30 days of old state versions; old backup versions are handled by restic.
resource "oci_objectstorage_object_lifecycle_policy" "tfstate" {
  namespace = local.namespace
  bucket    = oci_objectstorage_bucket.this["tfstate"].name

  depends_on = [oci_identity_policy.objectstorage_service]

  rules {
    name        = "expire-old-state-versions"
    action      = "DELETE"
    is_enabled  = true
    time_amount = 30
    time_unit   = "DAYS"
    target      = "previous-object-versions"
  }
}

resource "oci_limits_quota" "always_free" {
  count = var.enable_quotas ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "always-free-cap"
  description    = "Refuse anything beyond the Always Free amounts instead of billing it."
  statements     = var.quota_statements
}

# Oracle allows one budget on the tenancy. scripts/bootstrap.sh sets
# existing_budget_id when one was already made in the console; that budget and
# its alert rules are then kept as they are.
resource "oci_budget_budget" "cap" {
  count = var.existing_budget_id == "" ? 1 : 0

  compartment_id = var.tenancy_ocid
  display_name   = "always-free-guard"
  description    = "Anything above zero means something is not free."
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

resource "oci_budget_alert_rule" "forecast" {
  count = length(oci_budget_budget.cap)

  budget_id      = oci_budget_budget.cap[0].id
  display_name   = "forecast-above-one-percent"
  type           = "FORECAST"
  threshold_type = "PERCENTAGE"
  threshold      = 1
  recipients     = var.alert_email
  message        = "Oracle forecasts a charge this month. Check Billing -> Cost Analysis for what is not Always Free."
}

resource "oci_budget_alert_rule" "actual" {
  count = length(oci_budget_budget.cap)

  budget_id      = oci_budget_budget.cap[0].id
  display_name   = "actual-reached-budget"
  type           = "ACTUAL"
  threshold_type = "PERCENTAGE"
  threshold      = 100
  recipients     = var.alert_email
  message        = "Oracle charges reached the budget. Check Billing -> Cost Analysis now."
}

# Vault for the few secrets CI needs (Flux deploy key, SOPS age key).
# DEFAULT vaults and software keys are free; values are put in by
# scripts/put-flux-secrets.sh, never by OpenTofu, so they stay out of state.
resource "oci_kms_vault" "this" {
  compartment_id = local.compartment_id
  display_name   = "freetier"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "secrets" {
  compartment_id      = local.compartment_id
  display_name        = "secrets"
  management_endpoint = oci_kms_vault.this.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}
