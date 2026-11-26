data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_cluster_option" "oke" {
  cluster_option_id = "all"
  compartment_id    = var.compartment_ocid
}

locals {
  ad = data.oci_identity_availability_domains.this.availability_domains[0].name

  # Pick the newest version numerically ("v1.34.10" sorts after "v1.34.2").
  offered = {
    for v in data.oci_containerengine_cluster_option.oke.kubernetes_versions :
    format("%04d.%04d.%04d", [for p in split(".", trimprefix(v, "v")) : tonumber(p)]...) => v
    if can(regex("^v\\d+\\.\\d+\\.\\d+$", v))
  }
  k8s_version = var.kubernetes_version != "" ? var.kubernetes_version : local.offered[reverse(sort(keys(local.offered)))[0]]
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = "oke-free"
  type               = "BASIC_CLUSTER" # no control-plane fee
  kubernetes_version = local.k8s_version
  vcn_id             = oci_core_vcn.this.id

  endpoint_config {
    subnet_id            = oci_core_subnet.api.id
    is_public_ip_enabled = false
  }

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY" # VCN-native pods would be capped by the 1-OCPU shape's VNIC limit
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.public.id]

    kubernetes_network_config {
      pods_cidr     = local.pods_cidr
      services_cidr = local.svc_cidr
    }

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}

data "oci_containerengine_node_pool_option" "oke" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

locals {
  # Oracle Linux Arm images built for this Kubernetes version, newest first.
  node_images = reverse(sort([
    for s in data.oci_containerengine_node_pool_option.oke.sources :
    "${s.source_name}|${s.image_id}"
    if strcontains(s.source_name, "aarch64")
    && strcontains(s.source_name, "OKE-${trimprefix(local.k8s_version, "v")}-")
    && !strcontains(s.source_name, "GPU")
  ]))
}

locals {
  # The image the nodes run. PINNED by infra/node-image.auto.tfvars (written by the node-image workflow, merged by you): a newer Oracle image does nothing until a
  # reviewed pull request changes that file, so a plan never replaces the nodes on its own. Unpinned (variable empty) = the newest image, the old behaviour.
  node_image = var.node_image != "" ? var.node_image : local.node_images[0]

  # The node pool's Kubernetes version is the one in the image name (OKE-1.37.0-...). Oracle refuses (409) a pool whose kubernetes_version differs from the
  # version its image already sets, and the control plane may float ahead (cluster above): the workers move only when a reviewed node-image pull request
  # changes the image, which changes this version with it. Unpinned: the cluster's version, as before.
  pool_k8s_version = var.node_image != "" ? "v${regex("OKE-([0-9]+[.][0-9]+[.][0-9]+)-", var.node_image)[0]}" : local.k8s_version
}

# Warns (does not fail) while nothing pins the image: the next apply would take whatever Oracle published last and replace the nodes.
check "node_image_pinned" {
  assert {
    condition     = var.node_image != ""
    error_message = "node_image is not pinned (infra/node-image.auto.tfvars): an apply would use the newest Oracle image and replace the nodes. Run the node-image workflow once and merge its pull request (docs/NODE-IMAGE.md)."
  }
}

resource "oci_containerengine_node_pool" "arm" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_ocid
  name               = "arm"
  kubernetes_version = local.pool_k8s_version
  node_shape         = "VM.Standard.A1.Flex"

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = split("|", local.node_image)[1]
    boot_volume_size_in_gbs = tostring(var.node_boot_volume_gb)
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = local.ad
      subnet_id           = oci_core_subnet.workers.id
    }

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  initial_node_labels {
    key   = "freetier/pool"
    value = "arm"
  }

  # A new image or version replaces nodes one at a time when you apply (docs/NODE-IMAGE.md: what stays up, what restarts). The nodes are never patched in place.
  node_pool_cycling_details {
    is_node_cycling_enabled = true
    maximum_surge           = "0"
    maximum_unavailable     = "1"
  }

  lifecycle {
    precondition {
      condition     = var.node_count * var.node_ocpus <= 2 && var.node_count * var.node_memory_gb <= 12
      error_message = "The Always Free Arm allowance is 2 OCPU and 12 GB in total."
    }
    precondition {
      condition     = var.node_count * var.node_boot_volume_gb + (var.enable_micros ? 2 * var.micro_boot_volume_gb : 0) <= 200
      error_message = "Node and micro boot volumes together must fit the 200 GB Always Free disk."
    }
    precondition {
      condition     = var.node_image != "" || length(local.node_images) > 0
      error_message = "Oracle offers no aarch64 node image for ${local.k8s_version}; set kubernetes_version."
    }
  }
}
