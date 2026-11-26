variable "tenancy_ocid" {
  description = "Tenancy OCID (Profile menu -> Tenancy). Required."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.oc1\\.\\.[a-z0-9]{20,}$", var.tenancy_ocid))
    error_message = "tenancy_ocid looks like ocid1.tenancy.oc1..<letters and digits> (Console: profile menu -> Tenancy -> OCID -> Copy)."
  }
}

variable "region" {
  description = "Your HOME region (identifier such as eu-frankfurt-1). Always Free resources only exist there. Required: there is no default on purpose."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,3}-[a-z]+-[0-9]+$", var.region))
    error_message = "region is a region identifier such as af-johannesburg-1 or eu-frankfurt-1 (Console: top bar region menu -> Manage regions)."
  }
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config created by `oci session authenticate`."
  type        = string
  default     = "oracle-always-free-admin"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.oci_profile))
    error_message = "oci_profile is a profile name: letters, digits, dot, dash, underscore."
  }
}

variable "github_repository" {
  description = "owner/name of YOUR GitHub copy of this repository. The OIDC trust accepts tokens of this repository only. Required: there is no default on purpose."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must look like owner/name (your account and your PRIVATE copy), not a placeholder."
  }
}

variable "github_sub_prefix" {
  description = "Start of the GitHub OIDC sub claim for this repo, e.g. repo:Owner@123/name@456 with immutable subjects. Set by scripts/bootstrap.sh; empty means repo:<github_repository>."
  type        = string
  default     = ""

  validation {
    condition     = var.github_sub_prefix == "" || can(regex("^repo:[A-Za-z0-9@._/-]+$", var.github_sub_prefix))
    error_message = "github_sub_prefix is empty or starts with repo: and holds no wildcard, no colon and no space (it is matched with an exact `sub eq` rule)."
  }
}

variable "alert_email" {
  description = "Where budget alerts go. Also the contact email Oracle requires on the S3 users. Required."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s<>]+@[^@\\s<>]+\\.[^@\\s<>]+$", var.alert_email))
    error_message = "alert_email must be an e-mail address."
  }
}

variable "audit_email" {
  description = "Where the change alerts (quotas, policies, users, GitHub trust) go. Empty means alert_email. Set with AUDIT_EMAIL=... ./scripts/bootstrap.sh (it writes terraform.tfvars)."
  type        = string
  default     = ""

  validation {
    condition     = var.audit_email == "" || can(regex("^[^@\\s]+@[^@\\s]+$", var.audit_email))
    error_message = "audit_email must be empty or an email address."
  }
}

variable "budget_amount" {
  description = "Monthly budget in your billing currency. Alerts fire on a forecast above 1% of it and on reaching it."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_amount >= 1 && var.budget_amount <= 100
    error_message = "budget_amount is between 1 and 100: it is an alarm threshold, keep it low."
  }
}

variable "existing_budget_id" {
  description = "OCID of a budget already on the tenancy (made in the console). Set by scripts/bootstrap.sh; empty means create always-free-guard."
  type        = string
  default     = ""
}

variable "enable_quotas" {
  description = "Cap the tenancy at the Always Free amounts with quota policies."
  type        = bool
  default     = true
}

# Quota names: the -count ones are per availability domain, the -regional-count
# ones per region. Oracle's docs list only the first kind, but `zero
# compute-core quotas` also zeroes the regional ones and a node launch is
# checked against them (QuotaExceeded ... standard-a1-core-regional-count, 7 Nov
# 2026). Names confirmed with `oci limits definition list --service-name compute`.
# Statements run in order; a later one overrides an earlier one.
variable "quota_statements" {
  description = "Quota policy statements applied to the whole tenancy."
  type        = list(string)
  default = [
    "zero compute-core quotas in tenancy",
    "set compute-core quota standard-a1-core-count to 2 in tenancy",
    "set compute-core quota standard-a1-core-regional-count to 2 in tenancy",
    "set compute-memory quota standard-a1-memory-count to 12 in tenancy",
    "set compute-memory quota standard-a1-memory-regional-count to 12 in tenancy",
    "set compute-core quota standard-e2-micro-core-count to 2 in tenancy",
    "set block-storage quota total-storage-gb to 200 in tenancy",
    # Always Free object storage is 20 GB (Standard + Infrequent + Archive together); 20e9 bytes is under it in GB and in GiB.
    "set object-storage quota storage-bytes to 20000000000 in tenancy",
  ]
}
