terraform {
  required_version = ">= 1.12.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}

# Your own login, made with:
#   oci session authenticate --region <your-region> --profile-name oracle-always-free-admin
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = var.oci_profile
  region              = var.region
}
