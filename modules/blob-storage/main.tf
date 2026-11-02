# ------------------------------------------------------------------------------
# Blob Storage Module
# ------------------------------------------------------------------------------
# Creates Azure Blob Storage for Drupal media files:
#   - Storage account with configurable replication (LRS/GRS)
#   - Private container for Drupal media
#   - Optional soft delete and versioning
#   - RBAC role assignment for VMSS managed identity
#   - Optional private endpoint for secure access
#
# Integration:
#   Drupal accesses blobs via az_blob_fs module (native Azure Blob PHP SDK).
#   VMSS identity needs Storage Blob Data Contributor role.
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.11"
    }
  }
}

locals {
  # Storage account names must be 3-24 chars, lowercase alphanumeric only.
  #
  # This name is deliberately NOT derived from var.project_name. lib-main used
  # "drupal" (6) + "production" (10) + an 8-char suffix = exactly 24, leaving
  # zero headroom -- any longer project name overflows the limit and the apply
  # fails. var.storage_prefix is a short dedicated token and the environment is
  # abbreviated, so "vol" + "prod" + 8 = 15 with room to spare.
  env_short            = lookup(var.environment_abbreviations, var.environment, var.environment)
  storage_account_name = var.storage_account_name != null ? var.storage_account_name : "${var.storage_prefix}${local.env_short}${random_string.suffix[0].result}"
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Application = var.project_name
  })
}

# Random suffix for storage account name uniqueness (only if name not provided)
resource "random_string" "suffix" {
  count   = var.storage_account_name == null ? 1 : 0
  length  = 8
  special = false
  upper   = false
}

# Storage Account
resource "azurerm_storage_account" "drupal" {
  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = var.account_tier
  account_replication_type = var.replication_type
  account_kind             = "StorageV2"

  # Security settings
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = var.shared_access_key_enabled

  # Network rules (optional private access)
  dynamic "network_rules" {
    for_each = var.enable_network_rules ? [1] : []
    content {
      default_action             = "Deny"
      bypass                     = ["AzureServices"]
      ip_rules                   = var.allowed_ip_addresses
      virtual_network_subnet_ids = var.allowed_subnet_ids
    }
  }

  # Blob properties
  blob_properties {
    versioning_enabled = var.enable_versioning

    dynamic "delete_retention_policy" {
      for_each = var.soft_delete_retention_days > 0 ? [1] : []
      content {
        days = var.soft_delete_retention_days
      }
    }

    dynamic "container_delete_retention_policy" {
      for_each = var.container_soft_delete_retention_days > 0 ? [1] : []
      content {
        days = var.container_soft_delete_retention_days
      }
    }
  }

  tags = local.common_tags
}

# Per-resource Defender for Storage override (opt-out for non-prod accounts)
resource "azapi_resource" "defender_for_storage" {
  count     = var.disable_defender_for_storage ? 1 : 0
  type      = "Microsoft.Security/DefenderForStorageSettings@2022-12-01-preview"
  name      = "current"
  parent_id = azurerm_storage_account.drupal.id

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

# Blob container for Drupal media files
resource "azurerm_storage_container" "media" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.drupal.id
  container_access_type = "private"
}

# Developer read access to the shared devtest media container.
#
# Scoped to the CONTAINER and read-only, both deliberately. An earlier version
# gave each developer their own drupal-media-<username> container plus Storage
# Blob Data Contributor at ACCOUNT scope. That was removed on 2026-08-18: the
# per-dev containers were never wired to anything and always empty, and the
# account-scope grant defeated its own purpose -- it let every developer into
# every other container on the account, including one holding production
# database dumps, and made removing someone from this map fail to revoke them.
#
# The devs read the SAME container the dev-merge workflow refreshes from
# production, so there is one copy of the media and no per-person drift.
resource "azurerm_role_assignment" "dev_media_reader" {
  for_each             = var.developer_identities
  scope                = azurerm_storage_container.media.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = each.value
}

# Role assignment: Allow VMSS managed identity to access blobs
resource "azurerm_role_assignment" "vmss_blob_contributor" {
  count                = var.enable_vmss_blob_access ? 1 : 0
  scope                = azurerm_storage_account.drupal.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.vmss_principal_id
}

# Optional: Additional role assignments for other identities
resource "azurerm_role_assignment" "additional_blob_access" {
  for_each             = var.additional_principal_ids
  scope                = azurerm_storage_account.drupal.id
  role_definition_name = each.value.role
  principal_id         = each.value.principal_id
}

# Private endpoint (optional, for production)
resource "azurerm_private_endpoint" "blob" {
  count               = var.private_endpoint_subnet_id != null ? 1 : 0
  name                = "${local.storage_account_name}-blob-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${local.storage_account_name}-blob-psc"
    private_connection_resource_id = azurerm_storage_account.drupal.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  dynamic "private_dns_zone_group" {
    for_each = var.private_dns_zone_id != null ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_id]
    }
  }

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Production database dumps (devtest only)
# ------------------------------------------------------------------------------
# Devs have no other route to production data. Both PostgreSQL servers carry a
# single firewall rule, AllowAzureServices (0.0.0.0-0.0.0.0), so no laptop can
# reach them; and Azure Cloud Shell ships a PG 16 client that hard-refuses to
# read our PG 18 server, with no way to install a newer one because Cloud Shell
# now runs with the `no new privileges` flag and every sudo fails.
#
# GitHub Actions artifacts are NOT an alternative: an infra repo modelled on
# mccarthy-infra is PUBLIC, so an artifact holding users.pass hashes and
# users_field_data staff emails would be downloadable by anyone who can see the
# Actions tab. Hence a private container plus per-person RBAC.
#
# Written by .github/workflows/dump-production-db.yml.
resource "azurerm_storage_container" "db_dumps" {
  count                 = var.enable_db_dumps_container ? 1 : 0
  name                  = var.db_dumps_container_name
  storage_account_id    = azurerm_storage_account.drupal.id
  container_access_type = "private"
}

# Expire dumps so production copies do not accumulate.
#
# Two caveats worth knowing before trusting the number:
#   - Lifecycle management is a once-a-day best-effort sweep. Azure documents up
#     to 48h between a blob ageing out and actually being deleted.
#   - This account has blob soft delete on (var.soft_delete_retention_days), so a
#     deleted dump stays recoverable for that many days afterwards.
# Real worst-case lifetime is therefore retention + soft delete + a day or two.
#
# A storage account may hold exactly ONE management policy ("default"). Anything
# else needing lifecycle rules on this account must add a `rule` block here
# rather than a second azurerm_storage_management_policy resource.
resource "azurerm_storage_management_policy" "db_dumps" {
  count              = var.enable_db_dumps_container ? 1 : 0
  storage_account_id = azurerm_storage_account.drupal.id

  rule {
    name    = "expire-db-dumps"
    enabled = true

    filters {
      # Bare container name matches every blob inside it.
      prefix_match = [var.db_dumps_container_name]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.db_dump_retention_days
      }
    }
  }
}

# Developer read access to the dumps, on the same map as the media grant above.
# One list of developers, two container-scoped read-only grants. No shared
# secret travels with either: the dev signs in as themselves (`az login`) and
# reads with --auth-mode login. Nobody is handed a SAS token, a storage account
# key, or the database password.
#
# `.id` is the Resource Manager ID -- containers declared with
# storage_account_id (rather than the deprecated storage_account_name) use the
# Resource Manager API, and the resource documents import by that same ID. The
# `resource_manager_id` attribute is the deprecated spelling of it and is gone
# in provider 5.x. `.url` is the data-plane URL and is NOT a valid role scope.
resource "azurerm_role_assignment" "dev_db_dumps_reader" {
  for_each             = var.enable_db_dumps_container ? var.developer_identities : {}
  scope                = azurerm_storage_container.db_dumps[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = each.value
}
