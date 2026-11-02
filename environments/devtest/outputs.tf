output "resource_group_name" {
  description = "Name of the devtest resource group"
  value       = data.azurerm_resource_group.devtest.name
}

output "postgresql_fqdn" {
  description = "Fully qualified domain name of the devtest PostgreSQL server (set as the DEVTEST_DB_HOST repo variable)"
  value       = module.postgresql.fqdn
}

output "postgresql_server_name" {
  description = "Name of the devtest PostgreSQL server"
  value       = module.postgresql.server_name
}

output "postgresql_database_name" {
  description = "Name of the Drupal database"
  value       = module.postgresql.database_name
}

output "automation_account_name" {
  description = "Name of the Automation Account"
  value       = module.automation.automation_account_name
}

output "storage_account_name" {
  description = "Name of the devtest storage account (set as the DEVTEST_STORAGE_ACCOUNT repo variable)"
  value       = module.blob_storage.storage_account_name
}

output "storage_container_name" {
  description = "Name of the blob container"
  value       = module.blob_storage.container_name
}

output "db_dumps_container_name" {
  description = "Private container holding production database dumps"
  value       = module.blob_storage.db_dumps_container_name
}
