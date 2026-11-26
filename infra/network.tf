locals {
  vcn_cidr     = "10.0.0.0/16"
  api_cidr     = "10.0.0.0/28"
  workers_cidr = "10.0.10.0/24"
  public_cidr  = "10.0.20.0/24"
  pods_cidr    = "10.244.0.0/16"
  svc_cidr     = "10.96.0.0/16"
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "freetier"
  cidr_blocks    = [local.vcn_cidr]
  dns_label      = "freetier"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "internet"
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "nat"
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "oracle-services"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "private"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# Kubernetes API: reachable from inside the VCN only (nodes, Bastion sessions).
resource "oci_core_security_list" "api" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "api"

  ingress_security_rules {
    description = "Kubernetes API from the VCN"
    protocol    = "6"
    source      = local.vcn_cidr
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    description = "Node registration"
    protocol    = "6"
    source      = local.workers_cidr
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  ingress_security_rules {
    description = "Path MTU discovery"
    protocol    = "1"
    source      = local.vcn_cidr
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    description = "To the nodes"
    protocol    = "6"
    destination = local.workers_cidr
  }

  # The Bastion's endpoint sits in this subnet (bastion.tf) and its sessions open connections to the
  # API endpoint, which is also in this subnet. A security list filters traffic inside a subnet too,
  # so without this rule the tunnel opens but every request through it times out.
  egress_security_rules {
    description = "Bastion sessions to the Kubernetes API (same subnet)"
    protocol    = "6"
    destination = local.api_cidr
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  egress_security_rules {
    description = "SSH to the micros (Bastion sessions live in this subnet)"
    protocol    = "6"
    destination = local.public_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  egress_security_rules {
    description      = "To Oracle services (OKE control plane)"
    protocol         = "6"
    destination      = data.oci_core_services.all.services[0].cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
  }
}

# Nodes: everything inside the VCN, nothing from the internet.
# The cluster is reached through Cloudflare Tunnel and Tailscale, both outbound.
resource "oci_core_security_list" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "workers"

  ingress_security_rules {
    description = "Anything from inside the VCN"
    protocol    = "all"
    source      = local.vcn_cidr
  }

  ingress_security_rules {
    description = "Path MTU discovery"
    protocol    = "1"
    source      = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    description = "Outbound (images, tunnel, tailnet) through the NAT gateway"
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Micros: no inbound from the internet except Tailscale's direct-connection port.
# SSH only from inside the VCN (Bastion port-forwarding sessions).
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "public"

  ingress_security_rules {
    description = "SSH from Bastion sessions"
    protocol    = "6"
    source      = local.vcn_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    description = "Tailscale direct connections (WireGuard)"
    protocol    = "17"
    source      = "0.0.0.0/0"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  ingress_security_rules {
    description = "Path MTU discovery"
    protocol    = "1"
    source      = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    description = "Outbound"
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "api" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "api"
  cidr_block                 = local.api_cidr
  dns_label                  = "api"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.api.id]
}

resource "oci_core_subnet" "workers" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "workers"
  cidr_block                 = local.workers_cidr
  dns_label                  = "workers"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.workers.id]
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "public"
  cidr_block                 = local.public_cidr
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
}
