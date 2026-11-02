output "key_vault_id" {
  description = "Resource ID of the shared Key Vault"
  value       = azurerm_key_vault.shared.id
}

output "key_vault_name" {
  description = "Name of the shared Key Vault (use with az keyvault commands)"
  value       = azurerm_key_vault.shared.name
}

output "key_vault_uri" {
  description = "DNS-qualified URI of the shared Key Vault"
  value       = azurerm_key_vault.shared.vault_uri
}

output "resource_group_name" {
  description = "Resource group containing the shared Key Vault"
  value       = data.azurerm_resource_group.secrets.name
}
