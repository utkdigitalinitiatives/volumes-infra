# Resource Group
output "resource_group_name" {
  description = "Name of the production resource group"
  value       = data.azurerm_resource_group.production.name
}

# Networking
output "vnet_id" {
  description = "ID of the VNet"
  value       = module.networking.vnet_id
}

output "web_subnet_id" {
  description = "ID of the web subnet"
  value       = module.networking.web_subnet_id
}

# Load Balancer
output "lb_public_ip" {
  description = "Public IP address of the Load Balancer"
  value       = module.load_balancer.public_ip_address
}

output "lb_fqdn" {
  description = "FQDN of the Load Balancer (if dns_label is set)"
  value       = module.load_balancer.public_ip_fqdn
}

output "application_url" {
  description = "URL to access the Drupal application"
  value = var.domain_name != null ? (
    var.enable_https ? "https://${var.domain_name}" : "http://${var.domain_name}"
    ) : (
    module.load_balancer.public_ip_fqdn != null ? "http://${module.load_balancer.public_ip_fqdn}" : null
  )
}

# PostgreSQL
output "postgresql_fqdn" {
  description = "FQDN of the PostgreSQL server"
  value       = module.postgresql.fqdn
}

output "postgresql_connection_string" {
  description = "PostgreSQL connection string (without password)"
  value       = module.postgresql.connection_string
  sensitive   = true
}

# Blob Storage
output "storage_account_name" {
  description = "Name of the storage account"
  value       = module.blob_storage.storage_account_name
}

output "storage_container_url" {
  description = "URL to the Drupal media container"
  value       = module.blob_storage.container_url
}

# VMSS
output "vmss_id" {
  description = "ID of the VMSS"
  value       = module.vmss.vmss_id
}

output "vmss_name" {
  description = "Name of the VMSS"
  value       = module.vmss.vmss_name
}

output "vmss_identity_principal_id" {
  description = "Principal ID of the VMSS managed identity"
  value       = module.vmss.vmss_identity_principal_id
}

# Drupal Admin Credentials
output "drupal_admin_password" {
  description = "Password for the Drupal admin user"
  value       = var.drupal_admin_password != null ? var.drupal_admin_password : random_password.drupal_admin.result
  sensitive   = true
}

# Quick Start
output "quick_start" {
  description = "Quick start information for production"
  value       = <<-EOT

    ======================================================================
    ${var.project_name} Production Deployment Complete!
    ======================================================================

    Application URL: ${var.domain_name != null ? (var.enable_https ? "https://${var.domain_name}" : "http://${var.domain_name}") : (module.load_balancer.public_ip_fqdn != null ? "http://${module.load_balancer.public_ip_fqdn}" : "N/A")}

    Drupal Admin:
      Username: ${var.drupal_admin_username}
      Password: (run 'terraform output -raw drupal_admin_password')

    PostgreSQL Server: ${module.postgresql.fqdn}
    Database Name: ${module.postgresql.database_name}

    Storage Account: ${module.blob_storage.storage_account_name}
    Media Container: ${module.blob_storage.container_name}

    To SSH to VMSS instances (via Azure Bastion or jumpbox):
      ssh ${var.admin_username}@<instance-ip>

    To check cloud-init status:
      ssh ${var.admin_username}@<ip> 'sudo cat /var/log/drupal-init.log'

    ======================================================================
  EOT
}
