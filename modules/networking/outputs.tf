output "vnet_id" {
  description = "ID of the Virtual Network"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the Virtual Network"
  value       = azurerm_virtual_network.main.name
}

output "vnet_address_space" {
  description = "Address space of the Virtual Network"
  value       = azurerm_virtual_network.main.address_space
}

output "web_subnet_id" {
  description = "ID of the web subnet (for VMSS Blue/Green)"
  value       = azurerm_subnet.web.id
}

output "web_subnet_name" {
  description = "Name of the web subnet"
  value       = azurerm_subnet.web.name
}

output "web_subnet_address_prefix" {
  description = "Address prefix of the web subnet"
  value       = azurerm_subnet.web.address_prefixes[0]
}

output "private_endpoints_subnet_id" {
  description = "ID of the private endpoints subnet (for PostgreSQL, Blob)"
  value       = azurerm_subnet.private_endpoints.id
}

output "private_endpoints_subnet_name" {
  description = "Name of the private endpoints subnet"
  value       = azurerm_subnet.private_endpoints.name
}

output "web_nsg_id" {
  description = "ID of the web subnet NSG"
  value       = azurerm_network_security_group.web.id
}

output "web_nsg_name" {
  description = "Name of the web subnet NSG"
  value       = azurerm_network_security_group.web.name
}

output "private_endpoints_nsg_id" {
  description = "ID of the private endpoints subnet NSG"
  value       = azurerm_network_security_group.private_endpoints.id
}
