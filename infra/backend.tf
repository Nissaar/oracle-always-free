# State in the tfstate bucket through Oracle's S3-compatible API. OpenTofu has
# no oci backend (built-in backends: opentofu.org/docs/language/settings/backends/configuration/).
# scripts/bootstrap.sh writes your namespace and your region into the endpoint and the
# region line (<namespace> and <region> below are placeholders: a backend block cannot
# use variables); everything else is fixed. bootstrap/backend.tf (written by bootstrap.sh) is the same with key
# bootstrap/terraform.tfstate.
#
# Credentials: the customer secret key of user s3-tfstate (bootstrap/identity.tf)
# in the AWS-style profile oracle-tfstate of ~/.aws/credentials. CI writes that
# profile from the secrets OCI_STATE_ACCESS_KEY_ID / OCI_STATE_SECRET_ACCESS_KEY
# (scripts/tfstate-profile.sh); the laptop gets it from bootstrap.sh. The OCI
# provider itself still logs in keyless (scripts/oci-login.sh).
#
# Locking: use_lockfile writes infra/terraform.tfstate.tflock with
# If-None-Match. Whether Oracle's S3 API honours that header is UNVERIFIED.
# The workflow concurrency groups are the real guard. If init or plan fails on
# the lock, set use_lockfile = false here and in bootstrap/backend.tf
# (README "State and locking").
terraform {
  backend "s3" {
    bucket  = "tfstate"
    key     = "infra/terraform.tfstate"
    region  = "<region>"
    profile = "oracle-tfstate"
    endpoints = {
      s3 = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"
    }

    # Oracle is S3-compatible, not AWS: path-style URLs, no AWS-only checks,
    # no new-style checksums.
    use_path_style              = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    use_lockfile = true
  }
}
