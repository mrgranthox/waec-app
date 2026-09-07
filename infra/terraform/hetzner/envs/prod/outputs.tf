output "server_ipv4" {
  description = "Public IPv4 — DNS A record for var.domain must point here."
  value       = hcloud_server.waec_node.ipv4_address
}

output "server_private_ip" {
  value = local.node_private_ip
}

output "wg_admin_endpoint" {
  description = "Admin SSH/ops go through WireGuard, never the public internet."
  value       = "${local.wg_admin_ip}/32 via ${hcloud_server.waec_node.ipv4_address}:51820"
}

output "firewall_id" {
  value = hcloud_firewall.edge.id
}
