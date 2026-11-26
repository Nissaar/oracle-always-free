# Free managed Bastion: short-lived SSH port-forwarding sessions into the VCN.
# flux-bootstrap.yml uses it to reach the private Kubernetes API once;
# afterwards you and ChatOps use the Tailscale operator instead.
resource "oci_bastion_bastion" "this" {
  compartment_id               = var.compartment_ocid
  name                         = "freetier"
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.api.id
  client_cidr_block_allow_list = var.bastion_allowed_cidrs # default open: sessions still need OCI IAM + a per-session SSH key
  max_session_ttl_in_seconds   = 10800
}
