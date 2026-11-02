output "resource_group_name" {
  description = "Name of the resource group"
  value       = data.azurerm_resource_group.dev.name
}

# VM outputs
output "vm_id" {
  description = "ID of the dev VM"
  value       = module.dev_vm.vm_id
}

output "vm_name" {
  description = "Name of the dev VM"
  value       = module.dev_vm.vm_name
}

output "private_ip_address" {
  description = "Private IP address of the dev VM"
  value       = module.dev_vm.private_ip_address
}

output "public_ip_address" {
  description = "Public IP address of the dev VM"
  value       = module.dev_vm.public_ip_address
}

output "ssh_connection_string" {
  description = "SSH connection command for the dev VM"
  value       = module.dev_vm.ssh_connection_string
}

output "vm_identity_principal_id" {
  description = "Principal ID of the VM's managed identity"
  value       = module.dev_vm.vm_identity_principal_id
}

# Image outputs
output "image_version" {
  description = "Image version deployed to VM"
  value       = var.image_version
}

output "image_id" {
  description = "Full image ID from gallery"
  value       = data.azurerm_shared_image_version.drupal.id
}
