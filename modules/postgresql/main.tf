# ------------------------------------------------------------------------------
# PostgreSQL Module
# ------------------------------------------------------------------------------
# Creates an Azure PostgreSQL Flexible Server for production Drupal:
#   - Configurable SKU (Burstable for PoC, General Purpose for production)
#   - Optional private network access via delegated subnet
#   - Firewall rules for Azure services and specific IPs
#   - Drupal database with UTF-8 encoding
#   - pg_trgm extension enabled (required by Drupal 11)
#
# Network modes:
#   - Public: Set delegated_subnet_id = null, configure firewall rules
#   - Private: Provide delegated_subnet_id and private_dns_zone_id
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71"
    }
  }
}

locals {
  # Must be project-scoped: the server name becomes the public DNS label
  # <name>.postgres.database.azure.com, so the unparameterized
  # "drupal-production-psql" that lib-main uses would collide.
  server_name = "${var.project_name}-${var.environment}-psql"
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Application = var.project_name
  })
}

# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "main" {
  name                = local.server_name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgresql_version

  # Configurable tier (Burstable for PoC, General Purpose for production)
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # Network access: public or private via delegated subnet
  public_network_access_enabled = var.delegated_subnet_id == null
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id

  # Backup configuration (production-appropriate defaults)
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # High availability (optional for production)
  dynamic "high_availability" {
    for_each = var.high_availability_mode != null ? [1] : []
    content {
      mode                      = var.high_availability_mode
      standby_availability_zone = var.standby_availability_zone
    }
  }

  zone = var.availability_zone

  tags = local.common_tags

  # Zone is auto-assigned by Azure if not specified and cannot be changed after creation
  lifecycle {
    ignore_changes = [zone]
  }
}

# Firewall rule: Allow Azure services (only when public access enabled)
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  count     = var.delegated_subnet_id == null && var.allow_azure_services ? 1 : 0
  name      = "AllowAzureServices"
  server_id = azurerm_postgresql_flexible_server.main.id

  # Special range that allows all Azure services
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Firewall rules: Allow specific IP addresses (only when public access enabled)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allowed_ips" {
  for_each = var.delegated_subnet_id == null ? { for idx, ip in var.allowed_ip_addresses : idx => ip } : {}

  name      = "AllowIP-${each.key}"
  server_id = azurerm_postgresql_flexible_server.main.id

  start_ip_address = each.value
  end_ip_address   = each.value
}

# Firewall rules: Allow IP ranges (only when public access enabled)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allowed_ranges" {
  for_each = var.delegated_subnet_id == null ? var.allowed_ip_ranges : {}

  name      = "AllowRange-${each.key}"
  server_id = azurerm_postgresql_flexible_server.main.id

  start_ip_address = each.value.start
  end_ip_address   = each.value.end
}

# Database for Drupal
resource "azurerm_postgresql_flexible_server_database" "drupal" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Enable pg_trgm extension (required by Drupal 11)
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PG_TRGM"
}
