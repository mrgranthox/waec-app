# Terraform + provider requirements for the Hetzner single-node stack.
# See plans/hetzner-infrastructure-plan.md §1.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "hcloud" {
  # HCLOUD_TOKEN env var (least-privilege project token, plan §10).
  token = var.hcloud_token
}
