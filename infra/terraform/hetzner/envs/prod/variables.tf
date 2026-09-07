variable "hcloud_token" {
  description = "Hetzner Cloud API token (least-privilege, 2FA on account). Prefer HCLOUD_TOKEN env."
  type        = string
  sensitive   = true
  default     = null
}

variable "server_type" {
  description = "Server model per infrastructure plan §1.1."
  type        = string
  default     = "cpx22"
}

variable "location" {
  description = "Primary fsn1; nbg1/hel1 acceptable alternates (plan §1.1)."
  type        = string
  default     = "fsn1"
}

variable "server_name" {
  type    = string
  default = "waec-prod-01"
}

variable "ssh_public_key" {
  description = "Admin SSH public key — reachable only via WireGuard (firewall has no public 22)."
  type        = string
}

variable "domain" {
  description = "Public edge domain for Let's Encrypt + nginx server_name."
  type        = string
  default     = "api.waecplatform.gh"
}

variable "wg_admin_public_key" {
  description = "WireGuard public key of the admin laptop (peer allowed-ips 10.0.2.2/32)."
  type        = string
}

variable "wg_server_private_key" {
  description = "WireGuard server private key. Generate once: wg genkey. Stored via SOPS ideally."
  type        = string
  sensitive   = true
}

variable "backups_enabled" {
  description = "Hetzner automated backups (+20% cost, plan §1.2)."
  type        = bool
  default     = true
}

locals {
  node_private_ip = "10.0.1.2"
  wg_server_ip    = "10.0.2.1"
  wg_admin_ip     = "10.0.2.2"
}
