# ------------------------------------------------------------------------------
# Production Environment
# ------------------------------------------------------------------------------
# Deploys the complete Drupal application stack:
#   - Networking: VNet, subnets, NSG with load balancer rules
#   - Load Balancer: Public Standard LB with health probes
#   - PostgreSQL: Flexible Server with 14-day backup retention
#   - Blob Storage: Media files accessed via az_blob_fs (Azure Blob File System)
#   - VMSS: Single instance with rolling updates (MaxSurge, zero downtime)
#
# The resource group is created by bootstrap/azure-setup.sh, not here, so the
# GitHub Actions service principal can be scoped per-RG instead of holding
# subscription-wide Contributor.
#
# Deployment:
#   terraform init -backend-config=backend.hcl \
#     -backend-config="use_oidc=true" \
#     -backend-config="use_azuread_auth=true"
#   terraform apply -var="image_version=0.0.1"
#
# WARNING: for any manual apply, pin -var="image_version=" to the image the
# production VMSS is CURRENTLY running. Otherwise a stale value in
# terraform.tfvars silently reimages production to an older build. CI is not
# affected: the workflow resolves the newest gallery version and passes it as an
# explicit -var, which overrides tfvars.
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.11"
    }
  }

  # Remote backend for CI/CD - values provided via -backend-config
  # For local development, run: terraform init -backend=false
  # For CI/CD, run: terraform init -backend-config="resource_group_name=..." -backend-config="storage_account_name=..." ...
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  environment = "production"
  common_tags = {
    Environment = local.environment
    ManagedBy   = "terraform"
    Application = "drupal"
    Project     = var.project_name
    CostCenter  = var.cost_center
  }
}

# Generate random hash salt for Drupal security
resource "random_password" "drupal_hash_salt" {
  length  = 64
  special = false
}

# Generate random Drupal admin password if not provided
# Use only shell-safe special characters to avoid escaping issues in cloud-init
resource "random_password" "drupal_admin" {
  length           = 24
  special          = true
  override_special = "!@#%^&*-_=+?"
}

# Resource group for all production resources. Created by bootstrap, read here.
data "azurerm_resource_group" "production" {
  name = "${var.project_name}-production-rg"
}

# Shared Key Vault provisioned by environments/secrets/.
# Read its outputs so consumers don't need to know the name's random suffix.
data "terraform_remote_state" "secrets" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tfstate_resource_group_name
    storage_account_name = var.tfstate_storage_account_name
    container_name       = var.tfstate_container_name
    key                  = "secrets/terraform.tfstate"
    use_oidc             = var.use_oidc
    use_azuread_auth     = var.use_azuread_auth
  }
}

data "azurerm_key_vault_secret" "db_admin_password" {
  name         = "production-db-admin-password"
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
}

# Allow the VMSS managed identity to read secrets from the shared vault at boot.
resource "azurerm_role_assignment" "vmss_kv_secrets_user" {
  scope                = data.terraform_remote_state.secrets.outputs.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.vmss.vmss_identity_principal_id
}

# Persist the hash salt and Drupal admin password to Key Vault so they can be
# retrieved without TF state access (e.g., for admin login or to rebuild a VM).
# Values are mirrored from the existing random_password resources; no rotation.
resource "azurerm_key_vault_secret" "drupal_hash_salt" {
  name         = "production-drupal-hash-salt"
  value        = random_password.drupal_hash_salt.result
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

resource "azurerm_key_vault_secret" "drupal_admin_password" {
  name         = "production-drupal-admin-password"
  value        = var.drupal_admin_password != null ? var.drupal_admin_password : random_password.drupal_admin.result
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# Mirror the storage account access key into KV so cloud-init can fetch it via
# managed identity instead of receiving it through templatefile() substitution.
# Long-term goal is to eliminate this entirely by switching az_blob_fs to MI auth.
resource "azurerm_key_vault_secret" "storage_account_key" {
  name         = "production-storage-account-key"
  value        = module.blob_storage.primary_access_key
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# Anubis signing key (ED25519 seed, 32 bytes as 64 hex characters). Every
# instance must sign with the same key: production runs up to two instances,
# and a rolling upgrade runs two at once, so a per-instance key would send a
# visitor back through the challenge each time the load balancer moved them.
# The VMSS fetches it at boot (fetch-secrets.sh); nothing else reads it.
resource "random_bytes" "anubis_signing_key" {
  length = 32
}

resource "azurerm_key_vault_secret" "anubis_signing_key" {
  name         = "production-anubis-signing-key"
  value        = random_bytes.anubis_signing_key.hex
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# Data source: Get image version from Azure Compute Gallery
data "azurerm_shared_image_version" "drupal" {
  count               = var.use_gallery_image ? 1 : 0
  name                = var.image_version
  image_name          = var.image_name
  gallery_name        = var.gallery_name
  resource_group_name = var.gallery_resource_group_name
}

# Staleness guard for the image version.
#
# The version is a moving target -- every app build publishes a new one -- and
# the old failure mode was silent: a forgotten -var took the tfvars value and
# reimaged production backwards from a plan that read as normal. var.image_version
# now has no default, so a missing value is a hard stop. This is the second half:
# it catches a value that is present but stale.
#
# "latest" resolves the newest version published to this image definition. The
# name attribute is not reliably the resolved version when "latest" is requested,
# so read the last segment of the resource ID instead.
data "azurerm_shared_image_version" "newest" {
  count               = var.use_gallery_image ? 1 : 0
  name                = "latest"
  image_name          = var.image_name
  gallery_name        = var.gallery_name
  resource_group_name = var.gallery_resource_group_name
  # Without this, "latest" is the lexically greatest name, so once versions
  # passed 0.0.9 the check below warned on every correct deploy that 0.0.9 was
  # newer than 0.0.17. Same fix lib-main-infra applied.
  sort_versions_by_semver = true
}

# A check block warns, it does not fail. That is deliberate: holding production
# on a known-good build while a newer one is investigated is legitimate, and a
# gate that blocks it would get worked around. The point is that deploying a
# non-newest image becomes a decision you can see, instead of an accident.
check "image_version_is_newest" {
  assert {
    condition = !var.use_gallery_image || var.image_version == "latest" || var.image_version == basename(data.azurerm_shared_image_version.newest[0].id)
    error_message = format(
      "image_version is %q, but the newest %s published to gallery %s is %q. Expected if you are deliberately holding a known-good build; otherwise this apply reimages production onto an older image.",
      var.image_version,
      var.image_name,
      var.gallery_name,
      basename(data.azurerm_shared_image_version.newest[0].id),
    )
  }
}

# Networking: VNet, subnets, NSG with Load Balancer rules
module "networking" {
  source = "../../modules/networking"

  project_name = var.project_name

  environment                             = local.environment
  resource_group_name                     = data.azurerm_resource_group.production.name
  location                                = var.location
  vnet_address_space                      = var.vnet_address_space
  web_subnet_address_prefix               = var.web_subnet_prefix
  private_endpoints_subnet_address_prefix = var.private_endpoints_prefix
  enable_load_balancer_rules              = true
  enable_front_door_rules                 = false
  allowed_ssh_cidr_blocks                 = var.allowed_ssh_cidr_blocks

  tags = local.common_tags
}

# Load Balancer: Public Standard LB
module "load_balancer" {
  source = "../../modules/load-balancer"

  project_name = var.project_name

  environment          = local.environment
  resource_group_name  = data.azurerm_resource_group.production.name
  location             = var.location
  dns_label            = var.public_ip_id == null ? var.lb_dns_label : null
  public_ip_id         = var.public_ip_id
  health_probe_path    = var.health_probe_path
  enable_https         = var.enable_https
  enable_outbound_rule = true

  tags = local.common_tags
}

# PostgreSQL: Flexible Server
module "postgresql" {
  source = "../../modules/postgresql"

  project_name = var.project_name

  environment                  = local.environment
  resource_group_name          = data.azurerm_resource_group.production.name
  location                     = var.location
  sku_name                     = var.postgresql_sku
  storage_mb                   = var.postgresql_storage_mb
  administrator_login          = var.db_admin_username
  administrator_password       = data.azurerm_key_vault_secret.db_admin_password.value
  database_name                = var.db_name
  postgresql_version           = var.postgresql_version
  backup_retention_days        = 14
  geo_redundant_backup_enabled = false
  allow_azure_services         = true

  # Public access - add your IP for management
  allowed_ip_addresses = var.db_allowed_ips

  tags = local.common_tags
}

# Blob Storage: Drupal media files
module "blob_storage" {
  source = "../../modules/blob-storage"

  project_name               = var.project_name
  storage_prefix             = var.storage_prefix
  environment                = local.environment
  resource_group_name        = data.azurerm_resource_group.production.name
  location                   = var.location
  container_name             = "drupal-media"
  replication_type           = "LRS"
  soft_delete_retention_days = 7
  enable_versioning          = false

  # Two-pass deployment: set false initially, true after VMSS exists
  enable_vmss_blob_access = var.enable_vmss_blob_access
  vmss_principal_id       = var.enable_vmss_blob_access ? module.vmss.vmss_identity_principal_id : null

  tags = local.common_tags
}

# SAS token for the Apache reverse proxy that serves blob media (read-only).
#
# The window is a variable, not timestamp()/timeadd() - those change on every
# plan and would reissue the SAS (and reimage the VMSS) on each apply. The
# tradeoff is that expiry is a hard date somebody must roll before it lapses:
# put a calendar reminder on media_sas_expiry.
data "azurerm_storage_account_sas" "media_read" {
  connection_string = module.blob_storage.primary_connection_string
  https_only        = true
  start             = var.media_sas_start
  expiry            = var.media_sas_expiry

  resource_types {
    service   = false
    container = false
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

# TLS certificate storage container (certs persist across VMSS instance replacements)
resource "azurerm_storage_container" "tls_certs" {
  name                  = "tls-certs"
  storage_account_id    = module.blob_storage.storage_account_id
  container_access_type = "private"
}

# ------------------------------------------------------------------------------
# Durable private:// storage (Azure Files)
# ------------------------------------------------------------------------------
# Azure Files share backing Drupal's private:// filesystem (editor-only webform
# and media uploads). Mounted over /var/www/drupal/private on each VMSS instance
# at boot by /opt/mount-private-files.sh (see cloud-init.tftpl). The base image
# already bakes $settings['file_private_path'] = '../private' and creates the
# directory (packer/ansible/playbook.yml), so there is no Drupal-side change
# here -- this only swaps the ephemeral per-instance directory for durable,
# shared storage, so uploads survive VMSS reimages and stay consistent across
# the surge instance during a zero-downtime rolling deploy. Served only through
# Drupal's access-controlled /system/files/ route, never via the public
# /drupal-media/ SAS proxy.
#
# Deliberately on its own storage account rather than module.blob_storage: SMB
# requires shared-key auth, so a share on the media account would pin shared-key
# access there (blocking its planned move to MI-only auth), and the media
# account's key/SAS exist to serve public content. A dedicated account keeps one
# consumer per credential and lets the two keys rotate independently.
#
# Ported from lib-main-infra, where this has been live and verified on
# production since 2026-08-05. Production only: the dev environment is destroyed
# and recreated on every promotion and its database is re-synced from
# production, so durable private files there would only accumulate orphans.
resource "random_string" "private_files_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "private_files" {
  # Same 3-24 char lowercase-alphanumeric limit as modules/blob-storage, and the
  # environment is abbreviated for the same reason: "vol" + "priv" + "prod" + 8
  # = 19 chars, with headroom.
  name                = "${var.storage_prefix}privprod${random_string.private_files_suffix.result}"
  resource_group_name = data.azurerm_resource_group.production.name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # CIFS/SMB authenticates with the account key; MI/OAuth is not an option for
  # kernel mounts, so shared-key access must stay enabled on this account.
  shared_access_key_enabled = true

  # Share-level soft delete (accidental share deletion; file-level restore via
  # snapshots).
  share_properties {
    retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_share" "drupal_private" {
  name               = "drupal-private"
  storage_account_id = azurerm_storage_account.private_files.id
  quota              = 100
  access_tier        = "TransactionOptimized"
}

# Per-resource Defender for Storage override (same pattern as
# modules/blob-storage): the subscription-level plan bills per account, but its
# malware scanning only hooks blob uploads -- this account's sole data path is
# the SMB share, which Defender cannot scan. The media account stays enrolled,
# where blob scanning is real.
#
# NOTE: Azure pre-creates the "current" singleton, so the first apply needs a
# one-time `terraform import` (see docs/TODO.md).
resource "azapi_resource" "private_files_defender_off" {
  type      = "Microsoft.Security/DefenderForStorageSettings@2022-12-01-preview"
  name      = "current"
  parent_id = azurerm_storage_account.private_files.id

  body = {
    properties = {
      isEnabled                         = false
      overrideSubscriptionLevelSettings = true
      malwareScanning = {
        onUpload = {
          isEnabled     = false
          capGBPerMonth = -1
        }
      }
      sensitiveDataDiscovery = {
        isEnabled = false
      }
    }
  }
}

# Mirror the private-files account key into KV so cloud-init can fetch it via
# managed identity at boot (same pattern as production-storage-account-key).
resource "azurerm_key_vault_secret" "private_files_storage_key" {
  name         = "production-private-files-storage-key"
  value        = azurerm_storage_account.private_files.primary_access_key
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# VMSS: Single instance with rolling updates
module "vmss" {
  source = "../../modules/drupal-vmss"

  project_name = var.project_name

  environment         = local.environment
  resource_group_name = data.azurerm_resource_group.production.name
  location            = var.location
  subnet_id           = module.networking.web_subnet_id

  # Image source: gallery or marketplace fallback
  source_image_id = var.use_gallery_image ? data.azurerm_shared_image_version.drupal[0].id : null

  vm_size        = var.vm_size
  instance_count = 1
  min_instances  = 1
  max_instances  = 2

  admin_username       = var.admin_username
  admin_ssh_public_key = var.admin_ssh_public_key
  os_disk_size_gb      = var.os_disk_size_gb

  health_probe_path = var.health_probe_path
  health_probe_port = 80

  enable_autoscaling = false

  # Connect to Load Balancer
  load_balancer_backend_pool_id = module.load_balancer.backend_pool_id

  # Cloud-init with database, storage, and Drupal configuration
  custom_data = templatefile("${path.module}/cloud-init.tftpl", {
    site_name               = var.drupal_site_name
    site_mail               = var.drupal_site_mail
    admin_username          = var.drupal_admin_username
    admin_mail              = var.drupal_admin_mail
    install_profile         = var.drupal_install_profile
    db_host                 = module.postgresql.fqdn
    db_name                 = module.postgresql.database_name
    db_user                 = var.db_admin_username
    kv_name                 = data.terraform_remote_state.secrets.outputs.key_vault_name
    env_name                = local.environment
    hash_salt_secret_name   = azurerm_key_vault_secret.drupal_hash_salt.name
    storage_account         = module.blob_storage.storage_account_name
    storage_container       = module.blob_storage.container_name
    storage_endpoint        = module.blob_storage.primary_blob_endpoint
    storage_key_secret_name = azurerm_key_vault_secret.storage_account_key.name
    # Azure Files share mounted over /var/www/drupal/private (durable private://)
    private_files_account         = azurerm_storage_account.private_files.name
    private_files_share           = azurerm_storage_share.drupal_private.name
    private_files_key_secret_name = azurerm_key_vault_secret.private_files_storage_key.name
    # Escape % so mod_rewrite doesn't interpret %2B / %2F / %3D as backreferences (%N).
    # The escaped \% becomes a literal % in the substitution; combined with [NE] flag
    # in the RewriteRule and proxy-nocanon env, the SAS reaches Azure verbatim.
    storage_sas_token      = replace(data.azurerm_storage_account_sas.media_read.sas, "%", "\\%")
    lb_fqdn                = module.load_balancer.public_ip_fqdn
    drupal_admin_password  = var.drupal_admin_password != null ? var.drupal_admin_password : random_password.drupal_admin.result
    drupal_site_uuid       = var.drupal_site_uuid
    domain_name            = var.domain_name
    enable_https           = var.enable_https
    anubis_key_secret_name = azurerm_key_vault_secret.anubis_signing_key.name
    # Postmark server "Libraries Website", for Drupal's own mail. Seeded by
    # hand so the token stays out of TF state. Deploy mail from the workflows
    # uses a different server ("DevOps", shared-postmark-api-token).
    postmark_token_secret_name = "production-drupal-postmark-token"
  })

  tags = merge(local.common_tags, {
    ImageVersion = var.use_gallery_image ? var.image_version : "marketplace"
  })
}
