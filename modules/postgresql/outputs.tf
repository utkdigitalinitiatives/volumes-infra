output "server_id" {
  description = "ID of the PostgreSQL Flexible Server"
  value       = azurerm_postgresql_flexible_server.main.id
}

output "server_name" {
  description = "Name of the PostgreSQL Flexible Server"
  value       = azurerm_postgresql_flexible_server.main.name
}

output "fqdn" {
  description = "Fully qualified domain name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "database_id" {
  description = "ID of the Drupal database"
  value       = azurerm_postgresql_flexible_server_database.drupal.id
}

output "database_name" {
  description = "Name of the Drupal database"
  value       = azurerm_postgresql_flexible_server_database.drupal.name
}

output "administrator_login" {
  description = "Administrator login username"
  value       = var.administrator_login
}

output "connection_string" {
  description = "PostgreSQL connection string (without password)"
  value       = "postgresql://${var.administrator_login}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${var.database_name}?sslmode=require"
  sensitive   = true
}

output "is_private" {
  description = "Whether the server uses private VNet access"
  value       = var.delegated_subnet_id != null
}
