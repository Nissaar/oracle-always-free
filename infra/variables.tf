variable "tenancy_ocid" {
  description = "Tenancy OCID. CI: repository variable OCI_TENANCY_OCID (TF_VAR_tenancy_ocid). Required."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.oc1\\.\\.[a-z0-9]{20,}$", var.tenancy_ocid))
    error_message = "tenancy_ocid looks like ocid1.tenancy.oc1..<letters and digits>."
  }
}

variable "compartment_ocid" {
  description = "The freetier compartment made by bootstrap/. CI: repository variable OCI_COMPARTMENT_OCID. Required."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.oc1\\.\\.[a-z0-9]{20,}$", var.compartment_ocid))
    error_message = "compartment_ocid looks like ocid1.compartment.oc1..<letters and digits> (output OCI_COMPARTMENT_OCID of bootstrap/)."
  }
}

variable "region" {
  description = "Your HOME region identifier, the same as in bootstrap/ (for example eu-frankfurt-1). CI: repository variable OCI_REGION. Required: no default on purpose."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,3}-[a-z]+-[0-9]+$", var.region))
    error_message = "region is a region identifier such as af-johannesburg-1 or eu-frankfurt-1."
  }
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config. CI writes profile CI (scripts/oci-login.sh); on a laptop set it to your admin profile."
  type        = string
  default     = "CI"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.oci_profile))
    error_message = "oci_profile is a profile name: letters, digits, dot, dash, underscore."
  }
}

variable "bastion_allowed_cidrs" {
  description = "Client networks the OCI Bastion accepts sessions from. A session still needs OCI IAM permission and a one-time SSH key, so the default is open (GitHub-hosted runners have no fixed address). Narrow it to your own addresses if you do not use flux-bootstrap.yml."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.bastion_allowed_cidrs) > 0 && alltrue([for c in var.bastion_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "bastion_allowed_cidrs is a non-empty list of IPv4 CIDR blocks such as 203.0.113.0/24."
  }
}

variable "kubernetes_version" {
  description = "OKE version, e.g. v1.34.1. Empty = newest Oracle offers; a newer one shows up in a plan as an upgrade."
  type        = string
  default     = ""
}

variable "node_count" {
  description = "Number of Arm worker nodes. node_count x node_ocpus must stay within the Always Free 2 OCPU (checked before anything is created)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 4 && floor(var.node_count) == var.node_count
    error_message = "node_count is a whole number between 1 and 4."
  }
}

# Always Free Arm: 2 OCPU and 12 GB in total.
variable "node_ocpus" {
  description = "OCPUs per Arm node (node_count x node_ocpus <= 2 on Always Free)."
  type        = number
  default     = 1

  validation {
    condition     = var.node_ocpus >= 1 && var.node_ocpus <= 4
    error_message = "node_ocpus is between 1 and 4."
  }
}

variable "node_memory_gb" {
  description = "GB of memory per Arm node (node_count x node_memory_gb <= 12 on Always Free)."
  type        = number
  default     = 6

  validation {
    condition     = var.node_memory_gb >= 1 && var.node_memory_gb <= 24
    error_message = "node_memory_gb is between 1 and 24."
  }
}

variable "node_boot_volume_gb" {
  description = "Per node. Boot volumes of nodes and micros share the 200 GB Always Free disk."
  type        = number
  default     = 50

  validation {
    condition     = var.node_boot_volume_gb >= 50
    error_message = "OKE node boot volumes must be at least 50 GB."
  }
}

variable "enable_micros" {
  description = "Create the two AMD micro VMs (micro-edge, micro-kuma). Confirmed in the review on 2026-11-06."
  type        = bool
  default     = true
}

variable "enable_micro_kuma" {
  description = "Create micro-kuma (a second Uptime Kuma that fetches AutoKuma monitor files from a git repository of yours, see docs/WHAT-YOU-DO.md step 14). OFF by default: it needs a git source and a Tailscale login you have to provide. Oracle may also have no free E2.1.Micro capacity (\"Out of host capacity\"): apply again later."
  type        = bool
  default     = false
}

variable "micro_boot_volume_gb" {
  description = "Boot volume of each micro VM, in GB (Oracle's minimum is 50). Shares the 200 GB Always Free disk with the nodes."
  type        = number
  default     = 50

  validation {
    condition     = var.micro_boot_volume_gb >= 50 && var.micro_boot_volume_gb <= 100
    error_message = "micro_boot_volume_gb is between 50 and 100."
  }
}

variable "micro_ssh_public_key" {
  description = "Public key for the ubuntu user on the micros (the PUBLIC half, one line). Reached only through the Bastion. CI: repository variable MICRO_SSH_PUBLIC_KEY. Empty = no SSH login possible (cloud-init still installs the stack)."
  type        = string
  default     = ""

  validation {
    condition     = var.micro_ssh_public_key == "" || can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+( .*)?$", var.micro_ssh_public_key))
    error_message = "micro_ssh_public_key is the content of an OpenSSH PUBLIC key file (ssh-ed25519 AAAA... comment), never the private key."
  }
}

variable "patch_reboot_mode" {
  description = "What the micros do about a reboot that an update needs: alert (default: reminder by ntfy every 7 days, you reboot with ChatOps `reboot micro-edge`), staggered (reboots by itself when needed on Fridays at 00:00 UTC = 04:00 local time) or none. Only read at creation: a machine that exists is changed with patch/apply-patching.sh. patch/README.md."
  type        = string
  default     = "alert"

  validation {
    condition     = contains(["alert", "staggered", "none"], var.patch_reboot_mode)
    error_message = "patch_reboot_mode must be alert, staggered or none."
  }
}

variable "node_image" {
  description = "Node image pin, \"<source name>|<image OCID>\", set by infra/node-image.auto.tfvars (the node-image workflow writes it, a pull request changes it). Empty = the newest image. docs/NODE-IMAGE.md."
  type        = string
  default     = ""

  validation {
    condition     = var.node_image == "" || can(regex("^[^|]+\\|ocid1\\.image\\.[^|]+$", var.node_image))
    error_message = "node_image must be \"<source name>|ocid1.image....\" or empty."
  }
}

