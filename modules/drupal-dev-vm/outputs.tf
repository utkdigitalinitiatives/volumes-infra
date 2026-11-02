output "vm_id" {
  description = "ID of the Virtual Machine"
  value       = azurerm_linux_virtual_machine.dev.id
}

output "vm_name" {
  description = "Name of the Virtual Machine"
  value       = azurerm_linux_virtual_machine.dev.name
}

output "private_ip_address" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.dev.private_ip_address
}

output "public_ip_address" {
  description = "Public IP address of the VM (if assigned)"
  value       = var.assign_public_ip ? azurerm_public_ip.dev[0].ip_address : null
}

output "vm_identity_principal_id" {
  description = "Principal ID of the system-assigned managed identity"
  value       = azurerm_linux_virtual_machine.dev.identity[0].principal_id
}

output "vm_identity_tenant_id" {
  description = "Tenant ID of the system-assigned managed identity"
  value       = azurerm_linux_virtual_machine.dev.identity[0].tenant_id
}

output "network_interface_id" {
  description = "ID of the network interface"
  value       = azurerm_network_interface.dev.id
}

output "admin_username" {
  description = "Admin username for SSH access"
  value       = var.admin_username
}

output "ssh_connection_string" {
  description = "SSH connection string for the VM"
  value       = var.assign_public_ip ? "ssh ${var.admin_username}@${azurerm_public_ip.dev[0].ip_address}" : "ssh ${var.admin_username}@${azurerm_network_interface.dev.private_ip_address}"
}
