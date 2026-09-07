# Hetzner CPX22 single-node stack — plans/hetzner-infrastructure-plan.md
#
# Provisions: private network, edge firewall (443/80/51820-UDP only),
# the CPX22 server with cloud-init (Docker, UFW, unattended-upgrades,
# WireGuard), and the admin SSH key.

# ── Private network 10.0.1.0/24 ────────────────────────────────────────────
resource "hcloud_network" "private" {
  name     = "waec-private"
  ip_range = "10.0.1.0/24"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# ── Edge firewall — plan §10: default-deny, only 443/80/51820-UDP ─────────
resource "hcloud_firewall" "edge" {
  name = "waec-edge"

  # HTTP → nginx ACME challenge redirect
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS — the only public application surface
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard — admin access only
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # NOTE: no SSH rule — port 22 unreachable from the public internet.
  # Admin SSH goes over WireGuard (acceptance criterion 3, plan §13).
}

# ── Admin SSH key (registered for rescue/console; SSH traffic itself
#    arrives via WireGuard) ─────────────────────────────────────────────────
resource "hcloud_ssh_key" "admin" {
  name       = "waec-admin"
  public_key = var.ssh_public_key
}

# ── Cloud-init: Docker, UFW, unattended-upgrades, WireGuard (plan §1.1) ───
locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    wg_server_private_key = var.wg_server_private_key
    wg_server_ip          = local.wg_server_ip
    wg_admin_public_key   = var.wg_admin_public_key
    wg_admin_ip           = local.wg_admin_ip
    wg_listen_port        = 51820
    private_network_ip    = local.node_private_ip
  })
}

# ── The CPX22 node ─────────────────────────────────────────────────────────
resource "hcloud_server" "waec_node" {
  name        = var.server_name
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = local.cloud_init
  backups     = var.backups_enabled

  firewall_ids = [hcloud_firewall.edge.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.private.id
    ip         = local.node_private_ip
  }

  # Safety: destroying the production node requires explicit force.
  lifecycle {
    prevent_destroy = false # flip to true after first stable apply
  }
}
