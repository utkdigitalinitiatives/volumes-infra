variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, poc, staging)"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "postgresql_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "18"
}

variable "sku_name" {
  description = "SKU for PostgreSQL Flexible Server. Burstable (B_Standard_B1ms) for PoC, General Purpose (GP_Standard_D2s_v3) for production"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Storage size in MB (minimum 32768 = 32 GB)"
  type        = number
  default     = 32768
}

variable "administrator_login" {
  description = "Administrator login username"
  type        = string
  default     = "drupaladmin"
}

variable "administrator_password" {
  description = "Administrator login password"
  type        = string
  sensitive   = true
}

variable "database_name" {
  description = "Name of the Drupal database"
  type        = string
  default     = "drupal"
}

variable "availability_zone" {
  description = "Availability zone for the primary server (1, 2, or 3; null for no preference)"
  type        = string
  default     = null
}

# Backup configuration
variable "backup_retention_days" {
  description = "Backup retention in days (7-35). Use 14 for PoC, 35 for production"
  type        = number
  default     = 14
}

variable "geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backups (recommended for production)"
  type        = bool
  default     = false
}

# High availability
variable "high_availability_mode" {
  description = "High availability mode: 'SameZone' or 'ZoneRedundant'. Set to null to disable"
  type        = string
  default     = null

  validation {
    condition     = var.high_availability_mode == null ? true : contains(["SameZone", "ZoneRedundant"], var.high_availability_mode)
    error_message = "high_availability_mode must be null, 'SameZone', or 'ZoneRedundant'."
  }
}

variable "standby_availability_zone" {
  description = "Availability zone for standby server when using high availability"
  type        = string
  default     = null
}

# Network configuration
variable "delegated_subnet_id" {
  description = "Subnet ID for private access (VNet integration). Set to null for public access"
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for VNet integration. Required when delegated_subnet_id is set"
  type        = string
  default     = null
}

variable "allow_azure_services" {
  description = "Allow Azure services to access the server (only applies with public access)"
  type        = bool
  default     = true
}

variable "allowed_ip_addresses" {
  description = "List of individual IP addresses allowed to connect (only applies with public access)"
  type        = list(string)
  default     = []
}

variable "allowed_ip_ranges" {
  description = "Map of IP ranges allowed to connect (only applies with public access)"
  type = map(object({
    start = string
    end   = string
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
