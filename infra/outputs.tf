output "cluster_id" {
  value = oci_containerengine_cluster.this.id
}

output "kubernetes_version" {
  value = local.k8s_version
}

output "api_private_endpoint" {
  description = "host:port of the private Kubernetes API (reached through the Bastion)."
  value       = oci_containerengine_cluster.this.endpoints[0].private_endpoint
}

output "bastion_id" {
  value = oci_bastion_bastion.this.id
}

output "node_image" {
  description = "Name of the image the nodes run (the pin, or the newest when nothing is pinned)."
  value       = split("|", local.node_image)[0]
}

output "node_image_pinned" {
  value = var.node_image != ""
}

output "node_image_newest" {
  description = "The newest aarch64 OKE image Oracle offers for this Kubernetes version (the node-image workflow proposes it)."
  value       = length(local.node_images) > 0 ? split("|", local.node_images[0])[0] : ""
}

output "micro_public_ips" {
  value = { for k, v in oci_core_instance.micro : k => v.public_ip }
}

output "micro_private_ips" {
  value = { for k, v in oci_core_instance.micro : k => v.private_ip }
}
