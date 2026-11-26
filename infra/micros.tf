# Two Always Free AMD micro VMs (1/8 OCPU, 1 GB), each running one Docker stack from stacks/<name>/:
#   micro-edge: Tailscale exit node + subnet router for the VCN, AdGuard Home, ghcr.io pull-through cache
#   micro-kuma: the "oracle" Uptime Kuma (Kuma + AutoKuma + git sync + heartbeat to Home)
# cloud-init copies the stack files listed here and the patch agent (patch/); secrets go into the stack's .env on the VM by hand
# (docs/WHAT-YOU-DO.md), never into OpenTofu state.
locals {
  micros = var.enable_micros ? toset(concat(["micro-edge"], var.enable_micro_kuma ? ["micro-kuma"] : [])) : toset([])

  # Files listed by name, never a glob: a local .env in stacks/ must never end up in user_data/state.
  micro_stacks = {
    micro-edge = {
      files     = ["docker-compose.yml", ".env.example", "resolv.conf", "adguard/AdGuardHome.yaml", "adguard/apply.sh"]
      autostart = true # needs no secret: Tailscale prints a login link
      # OS patching (patch/README.md): which containers must be back after a boot. micro-edge runs no Kuma.
      patch_args = "--kuma no --containers 'edge_tailscale edge_adguard edge_ghcr_cache' --ts-container edge_tailscale"
    }
    micro-kuma = {
      files      = ["docker-compose.yml", ".env.example", "serve.json", "sync.sh", "push.sh", "up.sh"]
      autostart  = false # needs .env first (git token, Kuma login): you run ./up.sh
      patch_args = "--kuma yes --containers 'kuma_tailscale kuma_app kuma_autokuma kuma_sync kuma_push' --ts-container kuma_tailscale --push-container kuma_push"
    }
  }
  # cloud-init user_data per micro. Oracle caps the metadata at 32,000 bytes (ssh key included): the lifecycle precondition below keeps 2 KB of room.
  micro_user_data = {
    for name in local.micros : name => base64gzip(templatefile("${path.module}/micro-cloud-init.yaml", {
      stack     = name
      autostart = local.micro_stacks[name].autostart
      files = {
        for f in local.micro_stacks[name].files :
        f => filebase64("${path.module}/../stacks/${name}/${f}")
      }
      # OS patching: the agent and its installer, by name (same two files as on the other machines). gzip'd one by one (cloud-init encoding gz+b64):
      # plain base64 would take user_data to ~31.5 KB of Oracle's 32,000 bytes, this way it is ~26 KB.
      patch_files = {
        for f in ["patch-agent", "apply-patching.sh"] :
        f => base64gzip(file("${path.module}/../patch/${f}"))
      }
      patch_args        = local.micro_stacks[name].patch_args
      patch_reboot_mode = var.patch_reboot_mode
    }))
  }
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "micro" {
  for_each = local.micros

  compartment_id      = var.compartment_ocid
  availability_domain = local.ad
  display_name        = each.key
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = tostring(var.micro_boot_volume_gb)
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = each.key
  }

  metadata = {
    ssh_authorized_keys = var.micro_ssh_public_key
    # gzip: Oracle caps metadata at 32,000 bytes and the kuma stack alone is ~26 KB as plain base64.
    # cloud-init unpacks it by itself.
    user_data = local.micro_user_data[each.key]
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  lifecycle {
    # user_data only runs on the first boot; a stack edit must not rebuild the VM.
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]

    precondition {
      condition     = length(local.micro_user_data[each.key]) <= 30000
      error_message = "The cloud-init user_data of ${each.key} is ${length(local.micro_user_data[each.key])} bytes: Oracle allows 32,000 for all metadata. Shrink patch/ or the stack files."
    }
  }
}
