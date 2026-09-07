# Remote state on Hetzner Object Storage (plan §1.1).
#
# Enable once the bucket exists:
#   1. hcloud console → Security → S3 credentials (or object storage bucket)
#   2. export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY + state bucket vars
#   3. uncomment the block below, then: terraform init
#
# Terraform state contains no secrets by default, but is access-controlled:
# bucket must be private; versioning recommended for rollback.
#
# terraform {
#   backend "s3" {
#     bucket                      = "waec-tfstate"
#     key                         = "prod/terraform.tfstate"
#     endpoint                    = "https://fsn1.your-objectstorage.com"
#     region                      = "fsn1"
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_metadata_api_check     = true
#     skip_requesting_account_id  = true
#     s3_use_path_style           = true
#     force_path_style            = true
#   }
# }
