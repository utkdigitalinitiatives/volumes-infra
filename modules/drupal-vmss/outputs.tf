output "vmss_id" {
  description = "ID of the Virtual Machine Scale Set"
  value       = azurerm_linux_virtual_machine_scale_set.drupal.id
}

output "vmss_name" {
  description = "Name of the Virtual Machine Scale Set"
  value       = azurerm_linux_virtual_machine_scale_set.drupal.name
}

output "vmss_unique_id" {
  description = "Unique ID of the Virtual Machine Scale Set"
  value       = azurerm_linux_virtual_machine_scale_set.drupal.unique_id
}

output "vmss_identity_principal_id" {
  description = "Principal ID of the system-assigned managed identity"
  value       = azurerm_linux_virtual_machine_scale_set.drupal.identity[0].principal_id
}

output "vmss_identity_tenant_id" {
  description = "Tenant ID of the system-assigned managed identity"
  value       = azurerm_linux_virtual_machine_scale_set.drupal.identity[0].tenant_id
}

output "autoscale_setting_id" {
  description = "ID of the autoscale setting (if enabled)"
  value       = var.enable_autoscaling ? azurerm_monitor_autoscale_setting.drupal[0].id : null
}
