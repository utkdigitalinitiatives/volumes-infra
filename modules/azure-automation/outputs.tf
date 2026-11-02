output "automation_account_id" {
  description = "ID of the Automation Account"
  value       = azurerm_automation_account.main.id
}

output "automation_account_name" {
  description = "Name of the Automation Account"
  value       = azurerm_automation_account.main.name
}

output "automation_principal_id" {
  description = "Principal ID of the Automation Account's managed identity"
  value       = azurerm_automation_account.main.identity[0].principal_id
}
