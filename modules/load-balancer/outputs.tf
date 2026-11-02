output "lb_id" {
  description = "ID of the Load Balancer"
  value       = azurerm_lb.main.id
}

output "lb_name" {
  description = "Name of the Load Balancer"
  value       = azurerm_lb.main.name
}

output "backend_pool_id" {
  description = "ID of the backend address pool (wire this to VMSS)"
  value       = azurerm_lb_backend_address_pool.vmss.id
}

output "backend_pool_name" {
  description = "Name of the backend address pool"
  value       = azurerm_lb_backend_address_pool.vmss.name
}

output "public_ip_id" {
  description = "ID of the public IP"
  value       = var.public_ip_id != null ? var.public_ip_id : azurerm_public_ip.lb[0].id
}

output "public_ip_address" {
  description = "Public IP address of the Load Balancer (null when using external IP)"
  value       = var.public_ip_id == null ? azurerm_public_ip.lb[0].ip_address : null
}

output "public_ip_fqdn" {
  description = "Fully qualified domain name of the public IP (null when using external IP or no dns_label)"
  value       = var.public_ip_id == null ? azurerm_public_ip.lb[0].fqdn : null
}

output "http_probe_id" {
  description = "ID of the HTTP health probe"
  value       = azurerm_lb_probe.http.id
}

output "frontend_ip_configuration_id" {
  description = "ID of the frontend IP configuration"
  value       = azurerm_lb.main.frontend_ip_configuration[0].id
}
